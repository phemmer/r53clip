require_relative '../spec_helper'
require_relative 'vagrant'

describe 'R53Clip' do
	before :all do
		Vagrant.start_all

		config = {
			'credentials' => {
				'key' => ENV['AWS_ACCESS_KEY'],
				'secret' => ENV['AWS_SECRET_KEY'],
			},
			'records' => {
				"test.#{ROUTE53_ZONE_NAME}" => {
					'source' => 'eth1',
				},
			},
		}
		Vagrant.put_file_content_all('/app/r53clip.yaml', config.to_yaml)
		Vagrant.background_all('sudo bin/r53clip start /app/r53clip.yaml')

		puts "========================================"
		puts "Initialization complete. Starting tests."
		puts "========================================"
	end
	after :all do
		puts "========================================"
		puts "Stopping servers."
		puts "========================================"
		#@v.stop
		Vagrant.execute_all('sudo fuser /app/ -s -k', :ignore)
	end

	it 'should have a zone' do
		expect(ROUTE53_ZONE.exists?).to be_true
	end

	it 'should have a test record with 3 values' do
		values = get_values
		Timeout::timeout(90) do
			while values.nil? or values.size != 3 do
				sleep 2
				values = get_values
			end
		end
			
		expect(values.size).to eq(3)
		expect(values).to include('172.16.10.101')
		expect(values).to include('172.16.10.102')
		expect(values).to include('172.16.10.103')
	end

	it 'should handle losing a node' do
		Vagrant.last.halt(:force)

		values = get_values
		Timeout::timeout(90) do
			while values.nil? or values.size != 2 do
				sleep 2
				values = get_values
			end
		end

		expect(values.size).to eq(2)
		expect(values).to include('172.16.10.101')
		expect(values).to include('172.16.10.102')


		# now recovery

		Vagrant.last.up
		Vagrant.last.background('sudo bin/r53clip start /app/r53clip.yaml')
		values = get_values
		Timeout::timeout(90) do
			while values.nil? or values.size != 3 do
				sleep 2
				values = get_values
			end
		end

		expect(values.size).to eq(3)
		expect(values).to include('172.16.10.101')
		expect(values).to include('172.16.10.102')
		expect(values).to include('172.16.10.103')
	end
end
