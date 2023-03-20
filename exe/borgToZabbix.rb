#!/usr/bin/env ruby

require 'zabbix_sender_api'
require 'json'
require 'optimist'
require 'date'
require 'open3'


opts = Optimist::options do
  opt :zabhost, "Zabbix host to attach data to", :type => :string
  opt :zabproxy, "Zabbix proxy to send data to", :type => :string, :required => true
  opt :zabsender, "Path to Zabbix Sender", :type => :string, :default => "/usr/bin/zabbix_sender"
  opt :borgparams, "Additional Borg parameters; permanent options are --verbose --stats --json --show-rc", :type => :string
  opt :borgsrc, "Source directory for Borg backup to read from", :type => :string, :required => true
  opt :borgrepo, "Destination for Borg backup repository", :type => :string, :required => true
  opt :borgarchive, "Name of borg Archive - default is current datetimestamp", :default => DateTime.now.strftime('%Y%m%dT%H%M%S')
end

stdout, stderr, status = Open3.capture3("sudo borg create --verbose --stats --json --show-rc #{opts[:borgparams]} #{opts[:borgrepo]}::#{opts[:borgarchive]} #{opts[:borgsrc]}")

#result = JSON.parse(%x(sudo borg create --verbose --stats --json --show-rc #{opts[:borgparams]} #{opts[:borgrepo]}::#{opts[:borgarchive]} #{opts[:borgsrc]}))
#puts "sudo borg create --verbose --stats --json --show-rc #{opts[:borgparams]} #{opts[:borgrepo]}::#{opts[:borgarchive]} #{opts[:borgsrc]}"

batch = Zabbix::Sender::Batch.new(hostname: opts[:zabhost])
batch.addItemData(key: 'jsonRaw', value: JSON.parse(stdout).to_json)
batch.addItemData(key: 'exitStatus', value: status.exitstatus)

sender = Zabbix::Sender::Pipe.new(proxy: opts[:zabproxy], path: opts[:zabsender])
puts sender.sendBatchAtomic(batch)



puts 'the end'
