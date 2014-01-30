class Vagrant
	require 'shellwords'

	def initialize()
		#raise ArgumentError, "Vagrantfile not found at #{vgfile_path.inspect}" unless File.exists?(vgfile_path)
	end
	def start(provision = true)
		Bundler.with_clean_env do
			system('vagrant', 'up', '--parallel')
			raise ArgumentError, "Failed to start vagrant instances" if $?.exitstatus > 0
			if provision == true then
				system('vagrant', 'provision')
				raise ArgumentError, "Failed to provision vagrant instances" if $?.exitstatus > 0
			elsif provision == :fast then
				execute_all('sudo /install')
			end
		end
	end
	def stop
		Bundler.with_clean_env do
			system('vagrant', 'halt')
		end
	end
	def execute(box, command, *opts)
		#cmdstr = Shellwords.escape(command)
		cmdstr = command
		io = nil
		Bundler.with_clean_env do
			io = IO.popen(['vagrant', 'ssh', box, '--', "cd /app; exec 2>&1 #{cmdstr}"])
		end
		output = []
		io.each_line do |line|
			output << line
			puts "#{box}: " + line unless opts.include?(:silent)
		end
		io.close
		status = $?.exitstatus
		[status, output]
	end
	def execute_all(command, *opts)
		['box1','box2','box3'].each do |box|
			status, output = execute(box, command, *opts)
			raise StandardError, "#{box}: exit=#{status}" if status > 0 and !opts.include?(:ignore)
		end
	end
	def background_all(command, *opts)
		['box1','box2','box3'].each do |box|
			Thread.new do
				status, output = execute(box, command, *opts)
				raise StandardError, "#{box}: exit=#{status}" if status > 0 and !opts.include?(:ignore)
			end
		end
	end

	def put_file_content(box, path, content)
		io = nil
		Bundler.with_clean_env do
			io = IO.popen(['vagrant', 'ssh', box, '--', "cat > #{Shellwords.escape(path)}"], 'w')
		end
		io.write(content)
		io.close
		status = $?.exitstatus
		raise StandardError, "Transfer failed" if status > 0
		nil
	end
	def put_file_content_all(*args)
		['box1','box2','box3'].each {|box| put_file_content(box, *args)}
	end
end
