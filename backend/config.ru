require_relative 'environment'

$stdout.sync = true # logs go to stdout; in a container that isn't a TTY, unsynced lines would wait in a buffer

# Boot: one log line and exit 1 when ENABLED_APPS is invalid (or MCP_ENABLED still set), DB_DIR or VAULTS_DIR is
# missing (not mounted), a vault in the database has no repo in VAULTS_DIR (its storage not mounted), admin is enabled
# without its env, the admin env / INIT_* is partial / invalid, ALLOWED_VAULTS is invalid or, with sync, leaves out
# INIT_VAULT_NAME.
# The database file itself is created and migrated; neither directory ever is. Then, where sync runs, what INIT_* asks
# for, if it's missing: its code is redeemed through /pair, and a process that can't redeem it shouldn't reset its
# wrong guesses with a restart
begin
  apps = Config.enabled_apps
  DB.current
  Vault.check!
  if apps.include?('admin')
    admin = Config.admin or raise Config::EnvValueNotDefined, 'ADMIN_USER`, `ADMIN_PASSWORD`, `SESSION_SECRET'
  end
  init = Config.init
  allowed = Config.allowed_vaults
  if apps.include?('sync') && init && allowed && !allowed.include?(init.vault)
    raise Config::EnvValueInvalid, 'INIT_VAULT_NAME must be one of ALLOWED_VAULTS'
  end
  EnvInit.call(init) if apps.include?('sync')
rescue StandardError => e
  abort "vault-sync: not starting: #{e.message}"
end

# For debugging, not for production. Never logs credentials in headers (Authorization: the token, Basic for the sync
# API, Bearer for MCP; cookies: the admin session; a proxy's: Proxy-Authorization, Cloudflare Access' service token and
# JWT; anything named like a secret), request bodies (file contents, the admin's password and forms, MCP tool
# arguments, pairing codes — only the query string) or answers, but for the routes in LOGGED_BODIES: no file content
# (/files, /merge, a manifest's paths, MCP's read_file), no new token (/pair). Who the request was for comes from App /
# McpEndpoint (env['vault_sync.auth'] — device name + vault, the scoped token's name, or that it was refused)
class LogRequestAndResponse
  SECRET_HEADERS = %w[
    HTTP_AUTHORIZATION HTTP_PROXY_AUTHORIZATION HTTP_COOKIE
    HTTP_CF_ACCESS_CLIENT_ID HTTP_CF_ACCESS_CLIENT_SECRET HTTP_CF_ACCESS_JWT_ASSERTION
  ].freeze
  SECRET_NAMES = /AUTH|TOKEN|SECRET|PASSWORD|PASSWD|COOKIE|SESSION|JWT|API_?KEY|SIGNATURE|CREDENTIAL/
  # Answers whose JSON carries neither vault content nor a secret
  LOGGED_BODIES = %w[/vaults].freeze

  def initialize(app); @app = app; end
  def call(env)
    return @app.call(env) if env['PATH_INFO'] == '/health' # Docker's healthcheck, every 30 s
    req = Rack::Request.new(env)

    headers = Hash[*env.select {|k,v| k.start_with?('HTTP_') && !SECRET_HEADERS.include?(k) && !SECRET_NAMES.match?(k) }
		  .collect {|k,v| [k.sub(/^HTTP_/, ''), v]}
		  .collect {|k,v| [k.split('_').collect(&:capitalize).join('-'), v]}
		  .sort
		  .flatten]

    puts "<-- #{req.request_method} #{req.url} #{req.GET.inspect} #{headers.inspect}"
    status, headers, body = @app.call(env)

    shown = LOGGED_BODIES.include?(req.path) ? (JSON.parse(body.first) rescue '- stripped -') : '- stripped -'
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

use CanonicalPath # first: a path any part of the stack might read two ways never reaches it
use ZeitwerkReloader if Config.zeitwerk_reload?
use LogRequestAndResponse if Config.verbose_http_logs?

puts "vault-sync: serving #{apps.join(', ')}"

# ALLOWED_VAULTS: said once, so a process serving fewer vaults than meant (or a typo) shows in the log
if allowed && apps.include?('sync')
  puts "vault-sync: sync allowed for #{allowed.join(', ')} only"
  unknown = allowed - Vault.names
  puts "vault-sync: ALLOWED_VAULTS: no vault #{unknown.join(', ')}" if unknown.any?
elsif allowed
  puts 'vault-sync: ALLOWED_VAULTS set, sync not enabled'
end

# Claude's connector: its own auth (a Bearer token), outside App's; not there at all unless enabled
if apps.include?('mcp')
  require_relative 'mcp_endpoint'
  map('/mcp') { run McpEndpoint }
end

# Admin panel: its own app, outside App's auth; not there at all unless enabled
if admin
  require_relative 'admin'
  map('/admin') { run Admin }
  puts 'vault-sync: admin without TOTP, the password alone protects it' unless admin.totp_secret
elsif Config.admin_env?
  puts 'vault-sync: admin env set, admin not enabled'
end

# Without sync: /health (every container's healthcheck), else the empty 404 of any unknown path. A disabled app's paths
# land here or in App's default-deny like any other: nothing says it runs elsewhere
NO_SYNC = lambda do |env|
  next [404, {}, []] unless env['PATH_INFO'] == '/health' && %w[GET HEAD].include?(env['REQUEST_METHOD'])

  [200, { 'content-type' => 'text/plain', 'cache-control' => 'no-store' }, env['REQUEST_METHOD'] == 'HEAD' ? [] : ['ok']]
end

if apps.include?('sync')
  require_relative 'app'
  run App
else
  run NO_SYNC
end
