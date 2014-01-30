require_relative '../spec_helper'
require_relative 'vagrant'

describe 'R53Clip' do
	before :all do
		@v = Vagrant.new
		@v.start

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
		@v.put_file_content_all('/app/r53clip.yaml', config.to_yaml)
		@v.background_all('sudo bin/r53clip start /app/r53clip.yaml')
	end
	after :all do
		#@v.stop
		@v.execute_all('sudo fuser /app/ -s -k', :ignore)
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
end
