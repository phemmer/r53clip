module Vagrant
end

class Vagrant::Box
	require 'shellwords'

	attr_reader :name

	def initialize(name)
		@name = name
	end
	def start(provision = true)
		Bundler.with_clean_env do
			system('vagrant', 'up', @name)
			raise ArgumentError, "Failed to start vagrant instances" if $?.exitstatus > 0
			if provision == true then
				self.provision
			elsif provision == :fast then
				self.install
			end
		end
	end
	def provision(fast = false)
		system('vagrant', 'provision', @name)
		raise ArgumentError, "Failed to provision vagrant instances" if $?.exitstatus > 0
	end
	def install
		execute('sudo /install')
	end
	def up
		start(:fast)
	end
	def halt(*opts)
		Bundler.with_clean_env do
			args = []

			args << '--force' if opts.include?(:force)

			system('vagrant', 'halt', @name, *args)
		end
	end
	alias_method :stop, :halt
	def execute(command, *opts)
		#cmdstr = Shellwords.escape(command)
		cmdstr = command
		io = nil
		Bundler.with_clean_env do
			io = IO.popen(['vagrant', 'ssh', @name, '--', "cd /app; exec 2>&1 #{cmdstr}"])
		end
		output = []
		io.each_line do |line|
			output << line
			puts "#{@name}: " + line unless opts.include?(:silent)
		end
		io.close
		status = $?.exitstatus
		[status, output]
	end
	def background(command, *opts)
		Thread.new do
			status, output = execute(command, *opts)
		end
	end
	def put_file_content(path, content)
		io = nil
		Bundler.with_clean_env do
			io = IO.popen(['vagrant', 'ssh', @name, '--', "cat > #{Shellwords.escape(path)}"], 'w')
		end
		io.write(content)
		io.close
		status = $?.exitstatus
		raise StandardError, "Transfer failed" if status > 0
		nil
	end
end

module Vagrant
	BOXES = Hash[['box1','box2','box3'].map {|name| [name, Vagrant::Box.new(name)]}]

	def self.parallel(&block)
		threads = []
		BOXES.values.each do |box|
			threads << Thread.new do
				block.call(box)
			end
		end
		threads.each {|thread| thread.join}
	end
	def self.start_all(provision = true)
		Bundler.with_clean_env do
			system('vagrant','up','--parallel')
		end
		parallel {|box| box.install()}
	end

	def self.execute_all(command, *opts)
		BOXES.values.each do |box|
			status, output = box.execute(command, *opts)
			raise StandardError, "#{box.name}: exit=#{status}" if status > 0 and !opts.include?(:ignore)
		end
	end
	def self.background_all(command, *opts)
		threads = []
		BOXES.values.each do |box|
			threads << box.background(command, *opts)
		end
	end

	def self.put_file_content_all(*args)
		BOXES.values.each {|box| box.put_file_content(*args)}
	end

	extend Enumerable
	def self.each(&block)
		BOXES.values.each(&block)
	end
	def self.[](index)
		if index.is_a?(Integer)
			BOXES.values[index]
		else
			BOXES[index]
		end
	end
	def self.last
		self[-1]
	end
	def self.first
		self[0]
	end
end
