class R53clip
	require 'corosync_commander'
	require 'yaml'
	require 'ipaddr'
	require 'aws-sdk'
	require 'net/http'
	require 'uri'

	attr_reader :cc

	def initialize(config_path)
		@config = YAML.load_file(config_path)

		AWS.config(:access_key_id => (@config['credentials'] && @config['credentials']['key']) || ENV['AWS_ACCESS_KEY'] || ENV['AWS_ACCESS_KEY_ID'], :secret_access_key => (@config['credentials'] && @config['credentials']['secret']) || ENV['AWS_SECRET_KEY'] || ENV['AWS_SECRET_ACCESS_KEY'])
		if AWS.config.access_key_id.nil? or AWS.config.secret_access_key.nil? then
			abort "Missing AWS credentials"
		end
	end

	def status
		records = self.records

		data = {}
		records.each do |record|
			zone = AWS::Route53.new.hosted_zones.enum.find{|zone| zone.name == record['zone']}
			rrset = zone.rrsets[record['name'], 'A']
			r53_ips = rrset.exists? ? rrset.resource_records.map{|rr| rr[:value]} : []
			data[record['name']] ||= [record['value'], r53_ips]
		end

		data
	end

	def start
		puts "START"
		@member_records = {}

		@cc = CorosyncCommander.new
		@cc.commands.register 'add records', &self.method(:cc_add_records)
		@cc.commands.register 'sync', &self.method(:cc_sync)
		@cc.commands.register 'get records', &self.method(:cc_get_records)
		@cc.on_confchg &self.method(:cc_confchg)
		@cc.on_quorumchg &self.method(:cc_quorumchg)

		@cc.join('r53clip')

		exe = @cc.execute([], 'get records')
		exe.to_enum.each do |response, sender|
			@member_records[sender.to_s] = response
		end

		send_records
		puts "START: Complete"
	end

	def stop(wait_ttl_expire = false)
		# similar to send_records except we clear the values
		puts "Stopping"
		records = self.records
		records.each {|record| record['value'] = nil}
		@cc.execute([], 'add records', records).wait
		@cc.execute([], 'sync').wait
		@cc.stop
		if wait_ttl_expire then
			ttl_max = 0
			records.each do |record|
				ttl = record['ttl'] || 30
				ttl_max = ttl if ttl > ttl_max
			end
			puts "Waiting for records to expire (#{ttl_max} seconds)"
			sleep ttl_max
		end
	end

	def records
		records = []
		@config['records'].each do |record_name, record_spec|
			record = {}
			records << record
			record['name'] = record_name
			record['name'] += '.' unless record['name'][-1] == '.'
			record['zone'] = record_spec['zone'] || record['name'].sub(/^[^.]+\./, '')
			record['zone'] += '.' unless record['zone'][-1] == '.'
			record['ttl'] = record_spec['ttl'] if record_spec['ttl']
			record['stopped'] = record_spec['stopped'] if record_spec['stopped']
			record['value'] = get_ip(record_spec['source'])
		end

		records
	end

	def cc_get_records(sender)
		records
	end

	def get_ip(source)
		begin
			if source.nil? then # get default IP
				gateway = %x{ip route show}.split("\n").find{|line| line.match(/^default via/)}.match(/^default via (\S+) .*/)[1]
				ip = %x{ip route get #{gateway}}.match(/\bsrc (\S+)\b/)[1]
			elsif source == 'EIP' then
				Net::HTTP.get_response(URI.parse('http://169.254.169.254/2012-01-12/meta-data/public-ipv4')).body
			elsif source.match(/^[0-9\.]+\/\d+/) then # it's a subnet
				subnet = IPAddr.new(source)
				ip = %x{ip addr show}.split("\n").find{|line| line.match(/inet ([^\/\s]+)/) and subnet.include?(IPAddr.new($1))}.match(/inet ([^\/\s]+)/)[1]
			elsif source.match(/^[0-9\.]+$/) then # it's an IP
				ip = source
			else # assume it's an interface name
				ip = %x{ip addr show dev #{source}}.match(/inet ([^\/\s]+)/)[1]
			end
		rescue => e
			$stderr.puts "Couldn't find IP address for #{source}"
		end
	end

	def send_records
		@cc.execute([], 'add records', records).wait
		# 'sync' is a separate call so that if several nodes call 'add ip' at the same time, we dont do a sync on each one.
		# The first node will call 'add ip' and it'll happen fast, so 'sync' is immediately after.
		#  Then the second node calls 'add ip', but the leader can't respond since sync from the first node is still in progress, so the call waits.
		#  Then a third node calls 'add ip', and it waits for the same reason.
		#  Then the sync completes and the 2 'add ip' operations go through.
		#  Then node 2 calls 'sync' which syncs the IPs for both node 2 and 3.
		#  Then node 3 calls 'sync' which hangs because the sync from node 2 is still in progress.
		#  Then the sync completes and the leader processes the third sync. This one immediately goes through since it was handled in the second sync.
		@cc.execute([], 'sync').wait
	end

	def cc_add_records(sender, records)
		@member_records[sender.to_s] = records
	end

	def cc_confchg(current, left, joined)
		changes = false
		
		left.each do |node|
			# instead of deleting the record entirely, we delete the values so that we can make sure cc_sync knows it should clear the record
			next unless @member_records[node.to_s]
			changes = true
			@member_records[node.to_s].each do |record|
				record['value'] = nil
			end
		end

		@cc.execute([], 'sync') if changes and @cc.leader? # we use this instead of calling sync directly so that we can batch up multiple changes
	end

	def cc_quorumchg(quorate, node_list)
		Thread.new do # we have to run this in a separate thread because send_records does Corosync::CPG::Execution#wait, which cannot be run on the dispatch thread
			send_records
		end
	end

	def member_zone_records
		zone_records = {}
		@member_records.each do |node_id, records|
			records.each do |record|
				zone_name = record['zone'] || record['name'].sub(/^[^.]+/, '')
				zone_records[zone_name] ||= {}
				zone_record = zone_records[zone_name][record['name']] ||= {}
				zone_record['ttl'] ||= record['ttl'] if record['ttl']
				zone_record['values'] ||= []
				zone_record['values'] << record['value'] if record['value']
				zone_record['stopped'] = record['stopped'] if record['stopped']
			end
		end

		zone_records
	end

	def cc_sync(sender)
		return if !@cc.leader?
		#return if current_zone_records == @member_zone_records

		member_zone_records.each do |zone_name,records|
			zone = AWS::Route53.new.hosted_zones.enum.find{|zone| zone.name == zone_name}
			batch = AWS::Route53::ChangeBatch.new(zone.id)
			records.each do |zone_record_name,zone_record_data|
				rrset = zone.rrsets[zone_record_name,'A']

				values = zone_record_data['values']
				values = [zone_record_data['stopped']] if values.size == 0 and zone_record_data['stopped']
				
				next if rrset.exists? and rrset.resource_records.map{|rr| rr[:value]}.sort == values.sort # values already set to what they should be

				batch << rrset.new_delete_request if rrset.exists?

				batch << AWS::Route53::CreateRequest.new(zone_record_name, 'A', :ttl => zone_record_data['ttl'] || 30, :resource_records => values.map{|v| {:value => v}}) if values.size > 0

				puts "SYNC: Setting #{zone_record_name} #{values.inspect}"
			end
			if batch.size > 0 then
				change = batch.call
				$stdout.sync = true
				$stdout.write "SYNC: Waiting for change to complete (#{change.id}) "
				while change.status == 'PENDING' do
					$stdout.write '.'
					change = AWS::Route53::ChangeInfo.new(change.id)
					sleep 1
				end
				$stdout.write "\n"
				$stdout.sync = false
				#puts "STATUS=#{change.status}"
			end
		end

		# now that we've cleared any records which have no values, stop tracking those records
		@member_records.delete_if do |node_id, records|
			records.delete_if do |record|
				!record['value']
			end
			records.size == 0
		end
	end

	def current_zone_records
		if @cache_time and @cache_time < Time.new.to_i - ( @config['cache_expire'] || 30 ).to_i
			return @cache
		end

		@cache = member_zone_records
		@cache.each do |zone_name,records|
			zone = AWS::Route53.new.hosted_zones.enum.find{|zone| zone.name == zone_name}
			records.each do |zone_record_name,zone_record_data|
				rrset = zone.rrsets[zone_record_name, 'A']
				next unless rrset.exists?
				zone_record_data['values'] = rrset.resource_records.map{|rr| rr[:value]}
			end
		end

		@cache_time = Time.new.to_i
	end
end
