#!/usr/bin/env ruby

require 'zabbix_sender_api'
require 'json'
require 'optimist'
require 'date'
require 'open3'
require 'pry-byebug'
require 'logging'

opts = Optimist::options do
  banner <<-EOS
A wrapper script for Borg Prune 1.1.15

Example usage - Prunes backups older than 30 days Borg repo called "/mnt/backup/borg/myserver"
  Borg results will be sent to the zabbix server/proxy at 10.0.0.20 which is responsible for monitoring the host called myserver
./borgToZabbix.rb \\
--zabhost "myserver" \\
--zabproxy "10.0.0.20" \\
--zabsender "/usr/bin/zabbix_sender" \\
--kee-within 30d \\
--borg-repo "/mnt/backup/borg/myserver" \\
EOS
  opt :zabhost, "Zabbix host to attach data to", :type => :string
  opt :zabproxy, "Zabbix proxy to send data to", :type => :string, :required => true
  opt :zabsender, "Path to Zabbix Sender", :type => :string, :default => "/usr/bin/zabbix_sender"
  opt :sudo, "Run borg as root, carrying over BORG_PASSPHRASE var. User must have passwordless sudo privileges.", :default => false
  opt :'pass-file', "Path to file containing plain-text passphrase.", :type => :string
  opt :'common-opts', "Additional Common Options to apply as a quoted string", :type => :string
  opt :'borg-params', "Additional Borg Prune parameters as a quoted string; permanent options are --verbose --stats --show-rc", :type => :string
  opt :'dry-run', "do not change repository", :default => false
  opt :'keep-within', 'keep all archives within this time interval', :type => :string
  opt :'keep-secondly', "number of secondly archives to keep", :type => :string
  opt :'keep-minutely', "number of minutely archives to keep", :type => :string
  opt :'keep-hourly', "number of hourly archives to keep", :type => :string
  opt :'keep-daily', "number of daily archives to keep", :type => :string
  opt :'keep-weekly', "number of weekly archives to keep", :type => :string
  opt :'keep-monthly', "number of monthly archives to keep", :type => :string
  opt :'keep-yearly', "number of yearly archives to keep", :type => :string
  opt :'borg-repo', "repository to prune", :type => :string, :required => true
  opt :loglevel, "Extra logging", :type => :string, :default => "info"
end

# Capture the stdout, stderr, and status of Borg
def GetBytes(byte_str)
  # Return bytes as a float
  byte_split = byte_str.split(" ")
  case byte_split.last
  when "B"
    return byte_split.first.to_i
  when "KB"
    x = 1
  when "MB"
    x = 2
  when "GB"
    x = 3
  when "TB"
    x = 4
  when "PB"
    x = 5
  else
    abort ("Cannot convert '#{byte_str}' to bytes.")
  end

  return byte_split.first.to_i * 1000 ** x
end

log = Logging.logger(STDOUT)
log.level = opts[:loglevel].to_sym
# Set passphrase for password protected key
ENV["BORG_PASSPHRASE"] = File.read(opts[:'pass-file']).chomp! if opts[:'pass-file'] and File.exists?(opts[:'pass-file'])
log.warn("Neither passphrase file or BORG_PASSPHRASE environment variable found.") if not ENV.key?("BORG_PASSPHRASE")

# Check for sudo
sudo = nil
opts[:sudo] ? (sudo = "sudo --preserve-env=BORG_PASSPHRASE ") : ""
cmd = "#{sudo}borg prune -v --stats --show-rc "
cmd += "#{opts[:'dry-run'] ? '--list --dry-run' : nil} "
cmd += "#{opts[:borgparams]} "
cmd += "#{opts[:'keep-within'].nil? ? nil : ("--keep-within #{opts[:'keep-within']}")} "
cmd += "#{opts[:'keep-secondly'].nil? ? nil : ("--keep-secondly #{opts[:'keep-secondly']}")} "
cmd += "#{opts[:'keep-minutely'].nil? ? nil : ("--keep-minutely #{opts[:'keep-minutely']}")} "
cmd += "#{opts[:'keep-hourly'].nil? ? nil : ("--keep-hourly #{opts[:'keep-hourly']}")} "
cmd += "#{opts[:'keep-daily'].nil? ? nil : ("--keep-daily #{opts[:'keep-daily']}")} "
cmd += "#{opts[:'keep-weekly'].nil? ? nil : ("--keep-weekly #{opts[:'keep-weekly']}")} "
cmd += "#{opts[:'keep-monthly'].nil? ? nil : ("--keep-monthly #{opts[:'keep-monthly']}")} "
cmd += "#{opts[:'keep-yearly'].nil? ? nil : ("--keep-yearly #{opts[:'keep-yearly']}")} "
cmd += "#{opts[:'borg-repo']}"

# Clean up whitespace. This will cause issues if the borg repository has multiple consequtive whitespaces
cmd = cmd.gsub(/\s+/,' ')
log.info("Calling command:\n#{cmd}")
stdout, stderr, status = Open3.capture3(cmd)

if opts[:'dry-run']
  log.info("Dry run only")
  log.info("stdout:\n#{stdout}\n\nstderr:\n#{stderr}\n\nstatus:\n#{status}")
else
  log.info("Real run")
  log.info("stdout:\n#{stdout}\n\nstderr:\n#{stderr}\n\nstatus:\n#{status}")

  output = stderr.split("\n")
  output.shift
  output.shift

  # Find the deleted data stats
  m = /Deleted data:\s+(?<original>(?:-)?\d+(\.\d+)?\s(?:.)?B)\s+(?<compressed>(?:-)?\d+(\.\d+)?\s(?:.)?B)\s+(?<dedup>(?:-)?\d+(\.\d+)?\s(?:.)?B)/.match(output.first)
  
  # Instantiate a Zabbix Sender Batch object and add data to it - floats are required for negative representations in Zabbix
  batch = Zabbix::Sender::Batch.new(hostname: opts[:zabhost])
  batch.addItemData(key: 'prune.deleted.original_size', value: GetBytes(m['original']).to_f)
  batch.addItemData(key: 'prune.deleted.compressed_size', value: GetBytes(m['compressed']).to_f)
  batch.addItemData(key: 'prune.deleted.deduplicated_size', value: GetBytes(m['dedup']).to_f)
  batch.addItemData(key: 'prune.exit_status', value: status.exitstatus)

  # Send to Zabbix and output results and/or errors
  sender = Zabbix::Sender::Pipe.new(proxy: opts[:zabproxy], path: opts[:zabsender])
  puts batch.to_senderline
  puts sender.sendBatchAtomic(batch)
  log.error(stderr) if status.exitstatus != 0
end

