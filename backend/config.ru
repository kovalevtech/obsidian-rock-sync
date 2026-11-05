require_relative './app'

$stdout.sync = true # logs go to stdout; in a container that isn't a TTY, unsynced lines would wait in a buffer

# Boot: one log line and exit 1 when DB_DIR or VAULTS_DIR is missing (not mounted), a vault in the database has no
# repo in VAULTS_DIR (its storage not mounted), or the admin env / INIT_* is partial / invalid.
# The database file itself is created and migrated; neither directory ever is. Then what INIT_* asks for, if it's missing
begin
  DB.current
  Vault.check!
  admin = Config.admin
  EnvInit.call(Config.init)
rescue StandardError => e
  abort "vault-sync: not starting: #{e.message}"
end

# Never logs Authorization (it carries the token: Basic for the sync API, Bearer for MCP), cookies (the admin session),
# request bodies (file contents, the admin's password and forms, MCP tool arguments, pairing codes — only the query
# string), MCP answers (read_file's content) or /pair's (a new token): who the request was for comes from App /
# McpEndpoint (env['vault_sync.auth'] — device name + vault, the scoped token's name, or that it was refused)
class LogRequestAndResponse
  SECRET_HEADERS = %w[HTTP_AUTHORIZATION HTTP_COOKIE].freeze
  QUIET_BODIES = %r{\A/(mcp(/|\z)|pair\z)}

  def initialize(app); @app = app; end
  def call(env)
    return @app.call(env) if env['PATH_INFO'] == '/health' # Docker's healthcheck, every 30 s
    req = Rack::Request.new(env)

    headers = Hash[*env.select {|k,v| k.start_with?('HTTP_') && !SECRET_HEADERS.include?(k) }
		  .collect {|k,v| [k.sub(/^HTTP_/, ''), v]}
		  .collect {|k,v| [k.split('_').collect(&:capitalize).join('-'), v]}
		  .sort
		  .flatten]

    puts "<-- #{req.request_method} #{req.url} #{req.GET.inspect} #{headers.inspect}"
    status, headers, body = @app.call(env)

    shown = QUIET_BODIES.match?(req.path) ? '- stripped -' : (JSON.load(body.first) rescue '- stripped -')
    puts "--> #{status} #{env['vault_sync.auth']} #{shown.inspect} #{headers.except('set-cookie').inspect}"
    [status, headers, body]
  end
end

# Dev only. Reloads when a file under lib/ or services/ changed — not on every request: a reload ends the long polls — and
# one request at a time: unloading under a running request breaks it. Long polls (?wait=) skip that request lock, they
# would hold up everything for up to a minute; instead a reload closes them first (ChangeFeed.close_all: they answer,
# clients ask again), waits until they're out, and new ones wait until it's done.
class ZeitwerkReloader
  LOCK = Mutex.new
  POLLS = Mutex.new
  POLLS_CHANGED = ConditionVariable.new
  SOURCES = File.join(__dir__, '{lib,services}', '**', '*.rb')

  def initialize(app)
    @app = app
    @polls = 0
    @reloading = false
    @stamp = sources_stamp
  end

  def call(env)
    return long_poll(env) if Rack::Utils.parse_query(env['QUERY_STRING'].to_s).key?('wait')

    LOCK.synchronize do
      reload if sources_stamp != @stamp
      @app.call(env)
    end
  end

  private

  def long_poll(env)
    POLLS.synchronize do
      POLLS_CHANGED.wait(POLLS) while @reloading
      @polls += 1
    end
    begin
      @app.call(env)
    ensure
      POLLS.synchronize do
        @polls -= 1
        POLLS_CHANGED.broadcast
      end
    end
  end

  def reload
    POLLS.synchronize { @reloading = true }
    ChangeFeed.close_all
    POLLS.synchronize { POLLS_CHANGED.wait(POLLS) while @polls.positive? }
    $loader.reload
    @stamp = sources_stamp
  ensure
    POLLS.synchronize do
      @reloading = false
      POLLS_CHANGED.broadcast
    end
  end

  # Changes, added and removed files
  def sources_stamp
    Dir[SOURCES].sort.map { |f| [f, File.mtime(f)] }.hash
  end
end

use ZeitwerkReloader if Config.zeitwerk_reload?
use LogRequestAndResponse if Config.verbose_http_logs?

# Claude's connector: its own auth (a Bearer token), outside App's; not there at all unless asked for
if Config.mcp_enabled?
  require_relative 'mcp_endpoint'
  map('/mcp') { run McpEndpoint }
else
  puts 'vault-sync: MCP disabled'
end

# Admin panel: its own app, outside App's auth; not there at all without its env
if admin
  require_relative 'admin'
  map('/admin') { run Admin }
  puts 'vault-sync: admin without TOTP, the password alone protects it' unless admin.totp_secret
else
  puts 'vault-sync: admin disabled'
end

run App
