# Author:: KC Braunschweig (<kcb@fb.com>)
# Copyright:: Copyright (c) 2013-present Facebook
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# Returns a json object of key/value pairs suitable for time-series graphing.
# Run with -V for pretty-printed JSON. We assume this is running on the chef
# server. Many stats collectors hit localhost or run local binaries. We make
# assumptions that require Open Source Chef-server 11+ or Private Chef 2+
# and the omnibus install.
#
# Usage: knife exec chef-server-stats.rb
#
# Hostname for stats collected via http
server = 'localhost'

# Determine if we're running open source Chef server or private chef
if File.exists?('/opt/chef-server/bin/chef-server-ctl')
  running_osc = true
  embedded_path = '/opt/chef-server/embedded/bin'
elsif File.exists?('/opt/opscode/bin/private-chef-ctl')
  running_osc = false
  embedded_path = '/opt/opscode/embedded/bin'
else
  warn 'ERROR: Failed to determine chef server type, exiting'
  warn '       (open-source or privatechef)'
  exit 1
end

# Convenience method to do the thing that should return a hash. If it explodes
# for any reason just return an empty hash anyway so we can move on. We do this
# so we don't have to determine if we're running on OPC with a tiered
# architecture or OSC which could have services split in various ways. We just
# try every stat and report anything we're able to collect.
def _safe_get(name)
  begin
    yield
  rescue Exception => e
    if %w{info debug}.include?(Chef::Config[:log_level].to_s)
      warn "#{name}: #{e.message}"
      warn e.backtrace.inspect if Chef::Config[:log_level].to_s == 'debug'
    end
    return {}
  end
end

# Get counts from the chef server API
def get_api_counts
  _safe_get(__method__) do
    Chef::Config[:http_retry_count] = 0
    stats = {
      # Skip client count because searching is slow. Uncomment if you like.
      #'chef.server.num_clients' => search(:client, "*:*").count,
      'chef.server.num_nodes' => api.get('nodes').count,
      'chef.server.num_cookbooks' => api.get('cookbooks').count,
      'chef.server.num_roles' => api.get('roles').count,
    }
    return stats
  end
end

# Get couchdb stats
def get_couchdb_stats(running_osc, server)
  return {} if running_osc
  _safe_get(__method__) do
    stat_res = Net::HTTP.get_response(server, '/_stats', '5984').body
    parser = Yajl::Parser.new
    couch_stats = parser.parse(stat_res)

    stats = {
      'chef.server.couch_db_reads' =>
        couch_stats['couchdb']['database_reads']['current'],
      'chef.server.couch_db_writes' =>
        couch_stats['couchdb']['database_writes']['current'],
      'chef.server.couch_avg_request_time' =>
        couch_stats['couchdb']['request_time']['mean']
    }
    return stats
  end
end

# Get rabbitmq message count
def get_rabbitmq_stats(embedded_path)
  rabbit_bin = "#{embedded_path}/rabbitmqctl"
  return {} unless File.exists?(rabbit_bin)

  _safe_get(__method__) do
    cmd = "PATH=\"#{embedded_path}/:$PATH\" #{rabbit_bin}" +
          ' list_queues -p /chef messages_ready'
    s = Mixlib::ShellOut.new(cmd).run_command
    if s.exitstatus == 0
      lines = s.stdout.split(/\n/)
      # Values for all queues are listed on separate lines so add them up
      sum = 0
      lines.each do |line|
        # Skip lines that aren't values
        next unless /^\d+$/.match(line)
        sum += line.to_i
      end
      return { 'chef.server.rabbitmq_messages_ready' => sum }
    else
      return {}
    end
  end
end

# Collect postgresql stats
def get_postgresql_stats(embedded_path)
  psql_bin = "#{embedded_path}/psql"
  return {} unless File.exists?(psql_bin)
  # Stats to select and sum from pg_stat_all_tables (see postgresql docs)
  # http://www.postgresql.org/docs/current/static/monitoring-stats.html
  # Table 27-5. pg_stat_all_tables View
  columns = %w{
    seq_scan
    seq_tup_read
    idx_scan
    idx_tup_fetch
    n_tup_ins
    n_tup_upd
    n_tup_del
    n_live_tup
    n_dead_tup
  }

  _safe_get(__method__) do
    stats = {}
    q = "SELECT SUM(#{columns.join('), SUM(')}) FROM pg_stat_all_tables;"
    cmd = "su opscode-pgsql -c \"cd; #{psql_bin} -A -P tuples_only -U chef" +
          " -d opscode_chef -c '#{q}'\""

    s = Mixlib::ShellOut.new(cmd).run_command
    if s.exitstatus == 0
      s.stdout.split('|').each do |value|
        stats["chef.server.postgresql_#{columns.shift}"] = value.chomp
      end
    end

    # postgresql connection count
    q = "SELECT count(*) FROM pg_stat_activity WHERE datname = 'opscode_chef';"
    cmd = "su opscode-pgsql -c \"cd; #{psql_bin} -A -P tuples_only -U chef" +
          " -d opscode_chef -c \\\"#{q}\\\"\""

    s = Mixlib::ShellOut.new(cmd).run_command
    if s.exitstatus == 0
      stats['chef.server.postgresql_connection_count'] = s.stdout.chomp.to_i
    end

    return stats
  end
end

# Collect authz stats
def get_authz_stats(running_osc, server)
  return {} if running_osc
  # Grabs :9683/_ping from a chef server and pulls out interesting authz stats
  _safe_get(__method__) do
    stat_res = Net::HTTP.get_response(server, '/_ping', '9683').body
    parser = Yajl::Parser.new
    authz_stats = parser.parse(stat_res)
    stats = {}

    authz_stats['system_statistics'].each_key do |k|
      stats["chef.server.authz_#{k}"] =
        authz_stats['system_statistics'][k]['count']
    end
    return stats
  end
end

# Collect redis stats
def get_redis_stats
  return {} unless File.exists?('/opt/opscode/embedded/bin/redis-cli')
  # Pull interesting stats by using /opt/opscode/embedded/bin/redis-cli info
  _safe_get(__method__) do
    stats = {}
    single_keys = %w{keyspace_hits: keyspace_misses: used_memory:}

    s = Mixlib::ShellOut.new('/opt/opscode/embedded/bin/redis-cli info')
    lines = s.run_command.stdout.split
    lines.each do |line|
      next if line.empty?

      # There's one wonky line we have to handle specially
      if line =~ /db0:keys=(\d+),expires=(\d+)/
        stats['chef.server.redis_keys'] = $1
        stats['chef.server.redis_expires'] = $2
      end

      # Collect the lines we're interested in (defined by single_keys)
      next unless single_keys.any? { |k| line.match(k) }
      x = line.split(':')
      stats["chef.server.redis_#{x[0]}"] = x[1]
    end
    return stats
  end
end

# Check server status
def get_server_status(server)
  status = _safe_get(__method__) do
    uri = URI.parse("https://#{server}/_status")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)
    parser = Yajl::Parser.new
    status_hash = parser.parse(response.body)
    if status_hash['status'] == 'pong'
      server_status = { 'chef.server.status' => 1 }
    else
      server_status = { 'chef.server.status' => 0 }
    end
    return server_status
  end

  # If we threw an exception checking, treat that as failure.
  if status.empty?
    status = { 'chef.server.status' => 0 }
  end
  return status
end


# Get all the stats!
output = {}
output.merge!(get_api_counts)
output.merge!(get_couchdb_stats(running_osc, server))
output.merge!(get_rabbitmq_stats(embedded_path))
output.merge!(get_postgresql_stats(embedded_path))
output.merge!(get_authz_stats(running_osc, server))
output.merge!(get_redis_stats)
output.merge!(get_server_status(server))

# Generate output, pretty if necessary
if %w{info debug}.include?(Chef::Config[:log_level].to_s)
  output_json = JSON.pretty_generate(output)
else
  output_json = JSON.generate(output)
end

puts output_json
