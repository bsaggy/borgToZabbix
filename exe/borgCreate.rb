#!/usr/bin/env ruby

require 'zabbix_sender_api'
require 'json'
require 'optimist'
require 'date'
require 'open3'
require 'logging'
require 'pry-byebug'

opts = Optimist::options do
  banner <<-EOS
A wrapper script for Borg Create 1.1.15

Example usage - will backup everything under / except for /proc on myserver mounted at /mnt/myserver to borg repo /mnt/backup/borg/myserver with archive name 20230319T224500
  Borg results will be sent to the zabbix server/proxy at 10.0.0.20 which is responsible for monitoring the host called myserver
./borgToZabbix.rb \\
--zabhost "myserver" \\
--zabproxy "10.0.0.20" \\
--zabsender "/usr/bin/zabbix_sender" \\
--borg-params "--compression lz4 --exclude '/mnt/myserver/proc/*'" \\
--borg-path "/mnt/myserver" \\
--borg-repo "/mnt/backup/borg/myserver" \\
--borg-archive "20230319T224500" \\
EOS
  opt :zabhost, "Zabbix host to attach data to", :type => :string
  opt :zabproxy, "Zabbix proxy to send data to", :type => :string, :required => true
  opt :zabsender, "Path to Zabbix Sender", :type => :string, :default => "/usr/bin/zabbix_sender"
  opt :sudo, "Run borg as root, carrying over BORG_PASSPHRASE var. User must have passwordless sudo privileges.", :default => false
  opt :'pass-file', "Path to file containing plain-text passphrase.", :type => :string
  opt :'common-opts', "Additional Common Options to apply as a quoted string", :type => :string
  opt :'borg-params', "Additional Borg parameters; permanent options are --verbose --stats --json --show-rc", :type => :string
  opt :'borg-path', "Source directory for Borg backup to read from", :type => :string, :required => true
  opt :'borg-repo', "Destination for Borg backup repository", :type => :string, :required => true
  opt :'borg-archive', "Name of Borg Archive - default is current datetimestamp", :default => DateTime.now.strftime('%Y%m%dT%H%M%S')
  opt :loglevel, "Extra logging", :type => :string, :default => "info"
end

log = Logging.logger(STDOUT)
log.level = opts[:loglevel].to_sym
# Set passphrase for password protected key
ENV["BORG_PASSPHRASE"] = File.read(opts[:'pass-file']).chomp! if opts[:'pass-file'] and File.exists?(opts[:'pass-file'])

log.warn("Neither passphrase file or BORG_PASSPHRASE environment variable found.") if not ENV.key?("BORG_PASSPHRASE")

# Check for sudo
sudo = nil
opts[:sudo] ? (sudo = "sudo --preserve-env=BORG_PASSPHRASE ") : "" 
cmd = "#{sudo}borg create --verbose --stats --json --show-rc #{opts[:'borg-params']} #{opts[:'borg-repo']}::#{opts[:'borg-archive']} #{opts[:'borg-path']}"
log.info("Running command:\n#{cmd}")
begin
  # Capture the stdout, stderr, and status of Borg
  stdout, stderr, status = Open3.capture3(cmd)
  log.debug(stdout)
  log.debug(stderr)
  log.debug(status)
  
  # Instantiate a Zabbix Sender Batch object and add data to it
  batch = Zabbix::Sender::Batch.new(hostname: opts[:zabhost])
  batch.addItemData(key: 'jsonRaw', value: JSON.parse(stdout).to_json) if not stdout.empty?
  batch.addItemData(key: 'exitStatus', value: status.exitstatus)

  # Send to Zabbix and output results and/or errors
  sender = Zabbix::Sender::Pipe.new(proxy: opts[:zabproxy], path: opts[:zabsender])
  puts sender.sendBatchAtomic(batch)
  log.error(stderr) if status.exitstatus != 0

rescue Exception => e
  log.error(e)

ensure
  ENV.delete("BORG_PASSPHRASE")
end
