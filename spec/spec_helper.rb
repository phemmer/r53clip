def genid(prefix = '')
	@used ||= []
	string = nil
	begin
		string = prefix + (0...8).map { (65 + rand(26)).chr }.join
	end while @used.include?(string)
	string
end

ROUTE53_ZONE_NAME = genid("r53clip-").downcase + ".com."

require 'aws-sdk'
ar53 = AWS::Route53.new
ROUTE53_ZONE = ar53.hosted_zones.create(ROUTE53_ZONE_NAME)
ROUTE53_ZONE_ID = ROUTE53_ZONE.id

at_exit do
	begin
		Timeout::timeout(90) do
			batch = AWS::Route53::ChangeBatch.new(ROUTE53_ZONE_ID)
			ROUTE53_ZONE.resource_record_sets.each do |rr|
				next if rr.type == 'NS' or rr.type == 'SOA'
				batch << rr.new_delete_request
			end
			if batch.length > 0 then
				change = batch.call
				while change.status == 'PENDING' do
					change = AWS::Route53::ChangeInfo.new(change.id)
					sleep 1
				end
			end
			ROUTE53_ZONE.delete
		end
	rescue => e
		puts "#{e} (#{e.class.to_s})"
		$stderr.puts "Failed to clean up zone! Please do so manually: ZONE=#{ROUTE53_ZONE_NAME}"
	end
end

def get_values(name = 'test')
	record = "#{name}.#{ROUTE53_ZONE_NAME}"

	values = nil
	begin
		set = ROUTE53_ZONE.resource_record_sets[record, 'A']
		return nil if set.nil?
		values = set.resource_records.map{|rr| rr[:value]}
	rescue AWS::Core::Resource::NotFound => e
		return nil
	end

	values
end
