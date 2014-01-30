require 'rubygems'
require 'bundler/setup'
require 'rake'
require 'rspec/core/rake_task'

desc "Run all specs"
RSpec::Core::RakeTask.new(:spec)

desc "Generate upstart service file"
task "upstart" do
	depend_service = ENV['depend_service'] || 'corosync'
	run_dir = ENV['run_dir'] || '/tmp'
	app_dir = ENV['app_dir'] || File.expand_path('../', __FILE__)
	config_path = ENV['config_path'] || '/etc/r53clip.yaml'

	require 'erb'
	erb = ERB.new(File.read(File.expand_path('../service/r53clip.upstart.erb', __FILE__)), nil, '-')
	puts erb.result(binding)
end
