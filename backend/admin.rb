require_relative 'environment'
require 'digest'

# The admin panel at /admin (config.ru mounts it only with admin in ENABLED_APPS): vaults, device tokens, scoped tokens
# (MCP) and their grants. Outside App:
# App's device auth doesn't apply; its own login (user + password, + TOTP if it has a secret), session cookie and CSRF
# tokens do. Scoped tokens' pages always: /mcp may run in another process, which this one can't see. Not
# reloaded by Zeitwerk (like app.rb): its login state lives as long as the process (not shared with other processes).
class Admin < Sinatra::Base
  SESSION_TTL = 12 * 60 * 60 # s; the cookie expires then, and the server checks admin_at against it too

  # Login state of the process (one admin, in memory). A TOTP code works once (the step last used: ROTP's `after:`).
  # After MAX_FAILURES failures every login is refused until a lockout that doubles with each further failure, up to
  # MAX_LOCKOUT (else the admin's way in would be a restart) — refused, not slowed down: a sleep would hold a Puma
  # thread. A login resets it.
  class Gate
    MAX_FAILURES = 5
    LOCKOUT = 60 # s, the first one
    MAX_LOCKOUT = 60 * 60 # s

    def initialize(config, clock: -> { Time.now })
      @user = Digest::SHA256.digest(config.user)
      @password = Digest::SHA256.digest(config.password)
      @totp = config.totp_secret && ROTP::TOTP.new(config.totp_secret)
      @clock = clock
      @lock = Mutex.new
      @failures = 0
    end

    def now = @clock.call

    def totp? = !@totp.nil?

    # nil = signed in; else why not, for the log only (the page says the same for every failure)
    def check(user, password, code)
      @lock.synchronize do
        now = self.now
        return 'locked' if @locked_until && now < @locked_until

        # Digests: secure_compare wants equal lengths. Both compared, always
        known = Rack::Utils.secure_compare(Digest::SHA256.digest(user.to_s), @user) &
                Rack::Utils.secure_compare(Digest::SHA256.digest(password.to_s), @password)
        step = @totp&.verify(code.to_s.delete(' '), drift_behind: @totp.interval, drift_ahead: @totp.interval,
                                                    after: @last_step, at: now)
        if known && (step || !@totp)
          @last_step = step
          @failures = 0
          @locked_until = nil
          return
        end

        @failures += 1
        if @failures >= MAX_FAILURES
          @locked_until = now + [LOCKOUT * 2**[@failures - MAX_FAILURES, 16].min, MAX_LOCKOUT].min
        end
        known ? 'wrong or used code' : 'wrong user or password'
      end
    end
  end

  set :views, File.join(__dir__, 'views', 'admin')
  # Its stylesheet and script, at /admin/admin.css and /admin/admin.js: served before the filters, the login page
  # needs the stylesheet too
  set :public_folder, File.join(__dir__, 'public', 'admin')

  # Material Icons (Apache 2.0) as inline SVG paths: no icon font to load
  ICONS = {
    cloud: 'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z',
    folder: 'M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z',
    key: 'M12.65 10C11.83 7.67 9.61 6 7 6c-3.31 0-6 2.69-6 6s2.69 6 6 6c2.61 0 4.83-1.67 5.65-4H17v4h4v-4h2v-4H12.65zM7 14c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z',
    add: 'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z',
    logout: 'M10.09 15.59L11.5 17l5-5-5-5-1.41 1.41L12.67 11H3v2h9.67l-2.58 2.59zM19 3H5c-1.11 0-2 .9-2 2v4h2V5h14v14H5v-4H3v4c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2z',
    extension: 'M20.5 11H19V7c0-1.1-.9-2-2-2h-4V3.5C13 2.12 11.88 1 10.5 1S8 2.12 8 3.5V5H4c-1.1 0-1.99.9-1.99 2v3.8H3.5c1.49 0 2.7 1.21 2.7 2.7s-1.21 2.7-2.7 2.7H2V20c0 1.1.9 2 2 2h3.8v-1.5c0-1.49 1.21-2.7 2.7-2.7 1.49 0 2.7 1.21 2.7 2.7V22H17c1.1 0 2-.9 2-2v-4h1.5c1.38 0 2.5-1.12 2.5-2.5S21.88 11 20.5 11z',
    check: 'M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z',
    copy: 'M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z'
  }.freeze
  set :show_exceptions, false
  # Redirects as paths under /admin: behind a proxy the request's host / scheme may not be the browser's
  set :absolute_redirects, false
  set :prefixed_redirects, true

  config = Config.admin
  set :gate, Gate.new(config)

  # The session lives only here (path /admin), encrypted: admin_at (when the login happened) and the CSRF token
  use Rack::Session::Cookie, key: 'vault_sync_admin', path: '/admin', httponly: true, same_site: :strict,
                             secure: production?, expire_after: SESSION_TTL,
                             secrets: config.session_secret, serialize_json: true
  # Every POST carries the session's token (csrf_field): else 403
  use Rack::Protection::AuthenticityToken

  helpers do
    def h(text) = Rack::Utils.escape_html(text.to_s)

    # Paths under /admin for links and forms
    def path(to) = url(to, false)

    def csrf_field
      %(<input type="hidden" name="authenticity_token" value="#{h Rack::Protection::AuthenticityToken.token(session)}">)
    end

    def signed_in?
      at = session['admin_at']
      at.is_a?(Integer) && settings.gate.now.to_i - at < SESSION_TTL
    end

    def time(t) = t&.utc&.strftime('%Y-%m-%d %H:%M UTC')

    # 0 B, 512 B, 1.5 KB, 23 MB, 1.2 GB (1024-based)
    def bytes(n)
      return "#{n} B" if n < 1024

      units = %w[KB MB GB TB]
      exp = [(Math.log(n) / Math.log(1024)).floor, units.size].min
      value = n.to_f / 1024**exp
      value = value < 10 ? value.round(1) : value.round
      "#{value.to_s.delete_suffix('.0')} #{units[exp - 1]}"
    end

    # A static file's URL changes with the file: served with Last-Modified only, a browser keeps an old one for a while
    def asset(name) = path("/#{name}?v=#{File.mtime(File.join(settings.public_folder, name)).to_i}")

    # The side menu marks the page it's on
    def page?(to) = request.path_info == to

    def icon(name) = %(<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="#{ICONS.fetch(name)}"/></svg>)

    # A value in a field with a Copy button at its end (a check once copied); shown: how it reads, if not as copied
    def copyable(value, shown = value)
      <<~HTML
        <div class="copyable"><code>#{h shown}</code><button type="button" class="copy" title="Copy" aria-label="Copy"
          data-copy="#{h value}">#{icon(:copy)}#{icon(:check)}</button></div>
      HTML
    end
  end

  # Nothing but the login page without a session, unknown routes included
  # Scripts and styles from its own files only (admin.js wires the few behaviours: no inline handlers), nothing loaded
  # from elsewhere, forms posting here only, never in a frame
  CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; form-action 'self'; " \
        "frame-ancestors 'none'; base-uri 'none'"

  before do
    headers 'Cache-Control' => 'no-store', 'Content-Security-Policy' => CSP
    next if request.path_info == '/login'

    unless signed_in?
      session.clear
      redirect '/login'
    end
    env['vault_sync.auth'] = 'admin'
  end

  get '/login' do
    redirect '/' if signed_in?
    erb :login
  end

  post '/login' do
    if (reason = settings.gate.check(params['user'], params['password'], params['code']))
      env['vault_sync.auth'] = "admin: login failed (#{reason})"
      @error = 'Login failed.'
      halt 401, erb(:login)
    end
    session.clear
    request.session_options[:renew] = true
    session['admin_at'] = settings.gate.now.to_i
    env['vault_sync.auth'] = 'admin: signed in'
    redirect '/'
  end

  post '/logout' do
    session.clear
    redirect '/login'
  end

  get '/' do
    redirect '/vaults'
  end

  get '/vaults' do
    erb :vaults
  end

  post '/vaults' do
    Vault.create(params['name'].to_s)
    redirect '/vaults'
  rescue ArgumentError => e
    @vault_error = e.message
    halt 422, erb(:vaults)
  end

  # git gc for the vault, in the background: the page shows it running, then what it saved
  post '/vaults/:name/compact' do
    vault = Vault.find(params['name']) or halt 404
    vault.compact
    redirect '/vaults'
  end

  # Device tokens: a list (revoked ones with ?revoked=1, as on /scoped); each revoked or reconnected
  get '/tokens' do
    erb :tokens
  end

  post '/tokens/:id/revoke' do
    Devices.revoke(params['id'].to_i)
    redirect '/tokens'
  end

  # A code giving the token a new secret: the device keeps its name and vault (reinstalled, or its token lost)
  post '/tokens/:id/reconnect' do
    @code, @expires_at, @reconnect = Pairings.reconnect(params['id'].to_i)
    @vault = @reconnect[:vault]
    erb :pair
  rescue ArgumentError => e
    @tokens_error = e.message
    halt 422, erb(:tokens)
  end

  # Connecting a device: a vault (?vault= from the vaults page) → a one-time code for the plugin (Pairings). The code
  # goes into the POST's page only: not into a URL, not into the session
  get '/connect' do
    erb :connect
  end

  post '/connect' do
    @vault = params['vault'].to_s
    @code, @expires_at = Pairings.issue(@vault)
    erb :pair
  rescue ArgumentError => e
    @connect_error = e.message
    halt 422, erb(:connect)
  end

  # Scoped tokens (MCP): a list (revoked ones with ?revoked=1), and a page per token — its name and grants as one form,
  # checked and saved as a whole (Grants.check), errors on their rows

  get '/scoped' do
    erb :scoped
  end

  get '/scoped/new' do
    @form = { name: '', grants: [{ vault: Vault.names.first, folder: '', mode: 'rw', purpose: '' }] }
    erb :scoped_edit
  end

  # A new scoped token: the token goes into this page only (no redirect: not into a URL, not into the session), with
  # how to set up the connector
  post '/scoped' do
    @form = scoped_form
    halt 422, erb(:scoped_edit) if (@errors = Grants.check(@form[:grants])).any?

    device, @token = Devices.create_scoped(name: @form[:name], grants: @form[:grants])
    @scoped = Devices.find(device.id, kind: 'scoped')
    @mcp_url = "#{Config.mcp_base_url || Config.public_url}/mcp"
    erb :scoped_edit
  rescue ArgumentError => e
    @errors = { name: e.message }
    halt 422, erb(:scoped_edit)
  end

  # Saved grants that wouldn't pass any more (adding nothing, after a folder rename) show their errors right away
  get '/scoped/:id' do
    @scoped = scoped_token
    @form = { name: @scoped[:name], grants: Grants.of(@scoped[:id]).map { _1.to_h.except(:id) } }
    @errors = @scoped[:revoked_at] ? {} : Grants.check(@form[:grants])
    erb :scoped_edit
  end

  # Name and grants, both or nothing (the name first: it may be taken)
  post '/scoped/:id' do
    @scoped = scoped_token
    redirect "/scoped/#{@scoped[:id]}" if @scoped[:revoked_at]

    @form = scoped_form
    halt 422, erb(:scoped_edit) if (@errors = Grants.check(@form[:grants])).any?

    Devices.rename(@scoped[:id], @form[:name])
    Grants.replace(@scoped[:id], @form[:grants])
    redirect '/scoped'
  rescue ArgumentError => e
    @errors = { name: e.message }
    halt 422, erb(:scoped_edit)
  end

  post '/scoped/:id/revoke' do
    Devices.revoke(scoped_token[:id])
    redirect "/scoped/#{params['id'].to_i}"
  end

  # Download hosts (MCP's download_file, DownloadHosts): a list on the Scoped tokens page
  post '/hosts' do
    _, @hosts_error = DownloadHosts.add(params['host'])
    redirect '/scoped' unless @hosts_error

    @host_typed = params['host'].to_s
    halt 422, erb(:scoped)
  end

  post '/hosts/:id/remove' do
    DownloadHosts.remove(params['id'].to_i)
    redirect '/scoped'
  end

  helpers do
    def scoped_token = Devices.find(params['id'].to_i, kind: 'scoped') || halt(404)

    # The form's name and grant rows (grants[<n>][vault|folder|mode], in page order), folders normalized
    def scoped_form
      rows = params['grants'].is_a?(Hash) ? params['grants'].values.grep(Hash) : []
      grants = rows.map do
        { vault: _1['vault'].to_s, folder: Grants.normalize(_1['folder']), mode: _1['mode'].to_s,
          purpose: Grants.normalize_purpose(_1['purpose']) }
      end
      { name: params['name'].to_s.strip, grants: }
    end

    # notes:Inbox (rw), work:/ (w)
    def grant_label(grant) = "#{grant[:vault]}:#{grant[:folder].empty? ? '/' : grant[:folder]} (#{grant[:mode]})"
  end
end
