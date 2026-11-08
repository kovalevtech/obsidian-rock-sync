# frozen_string_literal: false
# The admin panel over HTTP, mounted as config.ru does (/admin next to App): login (password + TOTP, no replay,
# lockout), sessions, CSRF, vaults, devices
require_relative 'test_helper'
require_relative '../admin'

class AdminTest < VaultTest
  include Rack::Test::Methods

  def app = Rack::URLMap.new('/admin' => Admin, '/' => App)

  def setup
    super
    @now = Time.now
    Admin.set :gate, Admin::Gate.new(Config.admin, clock: -> { @now })
  end

  def code(at = @now) = ROTP::TOTP.new(ENV['ADMIN_TOTP_SECRET']).at(at)

  # The CSRF token of the session's last page, else of the login page (signed in: the page it redirects to)
  def csrf
    body = (last_response.body rescue '') # no request yet
    unless body.include?('authenticity_token')
      get '/admin/login'
      follow_redirect! while last_response.redirect?
      body = last_response.body
    end
    body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def post_form(path, params = {})
    post path, params.merge('authenticity_token' => csrf)
    last_response
  end

  def login(user: 'admin', password: 'correct horse', code: code())
    get '/admin/login'
    post_form '/admin/login', 'user' => user, 'password' => password, 'code' => code
  end

  def assert_login_page(res, what = nil)
    assert_equal 302, res.status, what
    assert_equal '/admin/login', res['Location'], what
  end

  def assert_refused(res, what = nil)
    assert_equal 401, res.status, what
    assert_includes res.body, 'Login failed.', what
    get '/admin/'
    assert_login_page last_response, what
  end

  # Every route Admin knows (HEAD included) with a concrete path, plus one it doesn't; the login page left out
  def routes
    Admin.routes.flat_map { |verb, list| list.map { |pattern, *| [verb, "/admin#{pattern.to_s.sub(':id', '1')}"] } }
      .reject { |_, path| path == '/admin/login' }
      .push(%w[GET /admin], %w[GET /admin/nope], %w[POST /admin/nope])
  end

  def test_every_route_needs_a_session
    routes.each do |verb, path|
      # POSTs with a valid CSRF token: the session check, not CSRF, is what refuses them
      custom_request(verb, path, verb == 'GET' || verb == 'HEAD' ? {} : { 'authenticity_token' => csrf })
      assert_login_page last_response, "#{verb} #{path}"
      assert_equal 'no-store', last_response['Cache-Control']
    end
    assert_equal %w[test], Vault.names
    assert_equal %w[test-device], DB[:devices].select_map(:name)
  end

  # The login page's stylesheet and script: no session needed
  def test_stylesheet_without_a_session
    get '/admin/login'
    assert_match(%r{href="/admin/admin.css\?v=\d+"}, last_response.body)
    assert_match(%r{<script src="/admin/admin.js\?v=\d+" defer>}, last_response.body)
    get '/admin/admin.css'
    assert_equal 200, last_response.status
    assert_match %r{\Atext/css}, last_response.content_type
    get '/admin/admin.js'
    assert_equal 200, last_response.status
    assert_match %r{\A(text|application)/javascript}, last_response.content_type
  end

  # Every page under the CSP, and nothing on them it would block: no inline handler, script or style
  def test_content_security_policy
    get '/admin/login'
    assert_equal Admin::CSP, last_response['Content-Security-Policy']
    login
    scoped, = Devices.create_scoped(name: 'claude', grants: [{ vault: 'test', folder: '', mode: 'rw', purpose: '' }])
    device = DB[:devices].where(name: 'test-device').get(:id)
    pages = %w[/admin/vaults /admin/tokens /admin/tokens?revoked=1 /admin/connect /admin/scoped /admin/scoped/new]
    pages << "/admin/scoped/#{scoped.id}"
    pages.each do |page|
      get page
      assert_equal 200, last_response.status, page
      assert_equal Admin::CSP, last_response['Content-Security-Policy'], page
      assert_no_inline(last_response.body, page)
    end
    post_form '/admin/connect', 'vault' => 'test'
    assert_no_inline(last_response.body, 'the pair page')
    post_form "/admin/tokens/#{device}/reconnect"
    assert_no_inline(last_response.body, 'a reconnect')
    post_form '/admin/scoped', 'name' => 'other', 'grants' => { '0' => { 'vault' => 'test', 'folder' => '', 'mode' => 'r' } }
    assert_includes last_response.body, 'id="token">Bearer '
    assert_no_inline(last_response.body, 'a new token')
  end

  def assert_no_inline(body, what)
    refute_match(/\s(on[a-z]+|style)=/i, body, what)
    refute_match(/<script(?![^>]*\ssrc=)/i, body, what)
    refute_match(/<style/i, body, what)
    refute_includes body, 'javascript:', what
  end

  def test_login
    get '/admin/login'
    assert_equal 200, last_response.status
    assert_equal 'no-store', last_response['Cache-Control']

    assert_equal '/admin/', login['Location']
    cookie = last_response['Set-Cookie']
    assert_match(/\Avault_sync_admin=/, cookie)
    assert_match(/; path=\/admin(;|\z)/, cookie)
    assert_match(/; httponly/i, cookie)
    assert_match(/; samesite=strict/i, cookie)
    refute_match(/; secure/i, cookie) # production only

    get '/admin/'
    assert_equal '/admin/vaults', last_response['Location']
    get '/admin/tokens'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'test-device'
    assert_equal 'no-store', last_response['Cache-Control']
  end

  def without_totp
    config = Config::Admin.new(user: 'admin', password: 'correct horse', totp_secret: nil,
                               session_secret: ENV.fetch('SESSION_SECRET'))
    Admin.set :gate, Admin::Gate.new(config, clock: -> { @now })
  end

  def test_the_login_page_asks_for_a_code_when_there_is_a_secret
    get '/admin/login'
    assert_includes last_response.body, 'name="code"'
  end

  def test_without_totp
    without_totp
    get '/admin/login'
    refute_includes last_response.body, 'name="code"'

    assert_refused login(password: 'wrong', code: ''), 'password'
    assert_refused login(user: 'root', code: ''), 'user'
    assert_equal '/admin/', login(code: '')['Location']
    post_form '/admin/logout'
    assert_equal '/admin/', login(code: '')['Location'], 'no code to use up: again right away'
  end

  def test_without_totp_lockout_still_counts
    without_totp
    5.times { assert_refused login(password: 'wrong', code: '') }
    assert_refused login(code: ''), 'locked: right password refused too'
    @now += 61
    assert_equal '/admin/', login(code: '')['Location']
  end

  # /mcp may run in another process (ENABLED_APPS): the panel always has the scoped tokens, behind its login
  def test_scoped_tokens_whatever_this_process_serves
    get '/admin/scoped'
    assert_login_page last_response
    login
    get '/admin/vaults'
    assert_includes last_response.body, 'Scoped tokens'
    Devices.create_scoped(name: 'claude')
    get '/admin/scoped'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'claude'
  end

  def test_wrong_credentials
    assert_refused login(password: 'wrong'), 'password'
    assert_refused login(user: 'root'), 'user'
    assert_refused login(code: code(@now + 120)), 'code'
    assert_refused login(code: ''), 'no code'
  end

  def test_a_code_works_once
    login
    post_form '/admin/logout'
    assert_login_page last_response
    assert_refused login, 'same code again'

    @now += 30
    assert_equal '/admin/', login['Location']
  end

  def test_a_code_from_the_neighbouring_step
    assert_equal '/admin/', login(code: code(@now - 30))['Location']
  end

  def test_lockout_doubles
    5.times { assert_refused login(password: 'wrong') }
    assert_refused login, 'locked: right credentials refused too'

    @now += 61
    assert_refused login(password: 'wrong'), 'one more failure: locked for twice as long'
    @now += 61
    assert_refused login, 'still locked'
    @now += 60
    assert_equal '/admin/', login['Location']

    post_form '/admin/logout'
    @now += 30
    assert_refused login(password: 'wrong'), 'reset by the login: a failure, not a lockout'
    assert_equal '/admin/', login(code: code)['Location']
  end

  # 12 failures: 60 s · 2^7 would be over two hours
  def test_lockout_stops_doubling_at_an_hour
    5.times { assert_refused login(password: 'wrong') }
    lock = 60
    7.times do
      @now += lock + 1
      assert_refused login(password: 'wrong')
      lock = [lock * 2, Admin::Gate::MAX_LOCKOUT].min
    end
    @now += Admin::Gate::MAX_LOCKOUT - 1
    assert_refused login, 'still locked'
    @now += 2
    assert_equal '/admin/', login['Location']
  end

  # Download hosts: typed as a host, a `*.` one, or a URL (its host); anything else refused, the list unchanged
  def test_download_hosts
    login
    get '/admin/scoped'
    assert_includes last_response.body, 'Download hosts'
    post_form '/admin/hosts', 'host' => ' https://Files.Example.com./pics/a.png '
    assert_equal '/admin/scoped', last_response['Location']
    post_form '/admin/hosts', 'host' => '*.cdn.example.com'
    post_form '/admin/hosts', 'host' => 'files.example.com'
    assert_equal %w[*.cdn.example.com files.example.com], DownloadHosts.hosts, 'twice: once'
    get '/admin/scoped'
    assert_includes last_response.body, '<code>files.example.com</code>'

    ['localhost', '1.2.3.4', 'exa mple.com', '*.com', 'example.com:443', '-x.example.com', 'пример.рф', 'a..b', ''].each do |typed|
      post_form '/admin/hosts', 'host' => typed
      assert_equal 422, last_response.status, typed
      assert_includes last_response.body, "isn&#39;t a host name", typed unless typed.empty?
      assert_includes last_response.body, %(name="host" placeholder=" " required value="#{Rack::Utils.escape_html(typed)}"), typed
    end
    assert_equal %w[*.cdn.example.com files.example.com], DownloadHosts.hosts

    post_form "/admin/hosts/#{DB[:download_hosts].where(host: 'files.example.com').get(:id)}/remove"
    assert_equal '/admin/scoped', last_response['Location']
    assert_equal %w[*.cdn.example.com], DownloadHosts.hosts
  end

  def test_download_hosts_matching
    assert DownloadHosts.allowed?('files.example.com', %w[files.example.com])
    assert DownloadHosts.allowed?('a.b.example.com', %w[*.example.com])
    refute DownloadHosts.allowed?('example.com', %w[*.example.com])
    refute DownloadHosts.allowed?('evilexample.com', %w[*.example.com example.com])
    refute DownloadHosts.allowed?('files.example.com.evil.org', %w[files.example.com])
    refute DownloadHosts.allowed?('x.files.example.com', %w[files.example.com])
    assert DownloadHosts.allowed?('FILES.example.com.', %w[files.example.com])
  end

  def test_post_without_csrf_token
    login
    post '/admin/vaults', 'name' => 'notes'
    assert_equal 403, last_response.status
    post '/admin/vaults', 'name' => 'notes', 'authenticity_token' => 'x' * 44
    assert_equal 403, last_response.status
    assert_equal %w[test], Vault.names

    clear_cookies
    post '/admin/login', 'user' => 'admin', 'password' => 'correct horse', 'code' => code
    assert_equal 403, last_response.status
  end

  def test_session_expires
    login
    @now += Admin::SESSION_TTL - 1
    get '/admin/vaults'
    assert_equal 200, last_response.status
    @now += 2
    get '/admin/vaults'
    assert_login_page last_response
    get '/admin/login'
    assert_equal 200, last_response.status
  end

  def test_create_vault
    login
    assert_equal '/admin/vaults', post_form('/admin/vaults', 'name' => 'notes')['Location']
    assert_equal %w[notes test], Vault.names
    assert Dir.exist?(File.join(@vaults_dir, 'notes', 'repo.git'))
    get '/admin/vaults'
    assert_includes last_response.body, '<td class="num muted">0 B</td>' # notes: no files yet

    get '/admin/'
    res = post_form('/admin/vaults', 'name' => 'Bad Name')
    assert_equal 422, res.status
    assert_includes res.body, 'bad vault name'
    res = post_form('/admin/vaults', 'name' => 'notes')
    assert_equal 422, res.status
    assert_includes res.body, 'vault notes exists'
    assert_equal %w[notes test], Vault.names
  end

  def test_connect_device_shows_a_code_that_gives_a_token
    Vault.create('other')
    login
    get '/admin/vaults'
    assert_includes last_response.body, 'href="/admin/connect?vault=other"'
    get '/admin/connect?vault=other'
    assert_includes last_response.body, '<option value="other" selected>'
    res = post_form('/admin/connect', 'vault' => 'other')
    assert_equal 200, res.status
    assert_equal 'no-store', res['Cache-Control']
    assert_includes res.body, 'Vault: <strong>other</strong>'
    assert_includes res.body, '<code>https://notes.example.com</code>'
    code = res.body[/<code>(\d{3} \d{3})</, 1]
    assert_includes res.body, "<code>https://notes.example.com?code=#{code.delete(' ')}</code>"
    assert code

    get '/admin/tokens'
    refute_includes last_response.body, code

    post '/pair', JSON.generate(code:, name: 'pixel'), 'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status
    device, = Devices.authenticate(JSON.parse(last_response.body).fetch('token'))
    assert_equal 'other', device.vault
    get '/admin/tokens'
    assert_includes last_response.body, '<td>pixel</td>'
  end

  def test_connect_device_needs_a_vault
    login
    get '/admin/connect'
    assert_includes last_response.body, '<option value="" selected disabled>Vault</option>'
    res = post_form('/admin/connect')
    assert_equal 422, res.status
    assert_includes res.body, 'no vault'
    assert_equal 422, post_form('/admin/connect', 'vault' => 'nope').status
    assert_includes last_response.body, 'no vault nope'
  end

  def test_reconnect_a_device
    login
    get '/admin/tokens'
    id = DB[:devices].where(name: 'test-device').get(:id)
    res = post_form("/admin/tokens/#{id}/reconnect")
    assert_equal 200, res.status
    assert_includes res.body, 'Reconnect test-device'
    assert_includes res.body, 'Vault: <strong>test</strong>'
    code = res.body[/<code>(\d{3} \d{3})</, 1]

    post '/pair', JSON.generate(code:, name: 'pixel'), 'CONTENT_TYPE' => 'application/json'
    assert_equal 'test-device', JSON.parse(last_response.body)['name']
    assert_equal [nil, :unknown], Devices.authenticate(@token)
  end

  def test_revoked_tokens_hidden
    Devices.create(name: 'old-phone', vault: 'test').first.then { Devices.revoke(_1.id) }
    login
    get '/admin/tokens'
    assert_includes last_response.body, '<td>test-device</td>'
    refute_includes last_response.body, 'old-phone'
    get '/admin/tokens?revoked=1'
    assert_includes last_response.body, '<td>old-phone</td>'
    assert_includes last_response.body, '<td>test-device</td>'
  end

  def test_compact_a_vault
    commit_file('a.md', "a\n")
    login
    get '/admin/vaults'
    assert_includes last_response.body, '<div class="muted nowrap">0 packs</div>'
    assert_equal '/admin/vaults', post_form('/admin/vaults/test/compact')['Location']
    Vault.find('test').instance_variable_get(:@compaction_thread).join
    get '/admin/vaults'
    assert_includes last_response.body, '<div class="muted nowrap">0 loose</div>'
    assert_includes last_response.body, '<div class="muted nowrap">1 pack</div>'
    assert_match(/history \d+(\.\d)? [KM]?B → \d+(\.\d)? [KM]?B/, last_response.body)
    assert_equal 404, post_form('/admin/vaults/missing/compact').status
  end

  # Scoped tokens (MCP)

  # Form fields for a token: name + grant rows ([vault, folder, mode])
  # Form fields for a token: name + grant rows ([vault, folder, mode, purpose?])
  def scoped_params(name, *grants)
    grants.each_with_index.to_h do |(vault, folder, mode, purpose), i|
      ["grants[#{i}]", { 'vault' => vault, 'folder' => folder, 'mode' => mode, 'purpose' => purpose.to_s }]
    end.merge('name' => name)
  end

  def grants_of(id) = Grants.of(id).map { [_1.vault, _1.folder, _1.mode] }

  def test_create_a_scoped_token_shows_it_once
    login
    get '/admin/scoped'
    assert_includes last_response.body, 'None yet.'
    get '/admin/scoped/new'
    assert_includes last_response.body, 'name="grants[0][folder]"'
    res = post_form('/admin/scoped', scoped_params('claude', %w[test Claude rw], ['test', ' /Claude/Inbox/ ', 'r']))
    assert_equal 422, res.status
    assert_includes res.body, '`r` on Claude/Inbox has no effect: Claude already gives rw.'
    assert_includes res.body, 'value="Claude/Inbox"', 'entered values kept (normalized)'
    assert_nil DB[:devices].where(name: 'claude').get(:id), 'nothing created'

    res = post_form('/admin/scoped', scoped_params('claude', %w[test Claude rw]))
    assert_equal 200, res.status
    assert_includes res.body, '<code class="token">https://notes.example.com/mcp</code>'
    secret = res.body[/<code class="token" id="token">Bearer ([A-Za-z0-9_-]{43})</, 1]
    token = Devices.authenticate(secret, kind: 'scoped').first
    assert_equal 'claude', token.name
    assert_equal [%w[test Claude rw]], grants_of(token.id)
    assert_includes res.body, %(action="/admin/scoped/#{token.id}"), 'the page edits the new token'

    get '/admin/scoped'
    assert_includes last_response.body, %(<a href="/admin/scoped/#{token.id}">claude</a>)
    assert_includes last_response.body, 'test:Claude (rw)'
    refute_includes last_response.body, secret
    get "/admin/scoped/#{token.id}"
    refute_includes last_response.body, secret
    get '/admin/tokens'
    refute_includes last_response.body, 'claude', 'device tokens only'

    ENV['MCP_BASE_URL'] = 'https://mcp.example.com/'
    get '/admin/scoped/new'
    assert_includes post_form('/admin/scoped', scoped_params('other', %w[test Inbox w])).body,
                    '<code class="token">https://mcp.example.com/mcp</code>'

    get '/admin/scoped/new'
    res = post_form('/admin/scoped', scoped_params('Bad Name', %w[test Inbox w]))
    assert_equal 422, res.status
    assert_includes res.body, 'bad name'
    assert_includes res.body, 'value="Inbox"'
    get '/admin/scoped/new'
    assert_equal 200, post_form('/admin/scoped', scoped_params('test-device', %w[test Inbox w])).status,
                 'a name a device token has'
    get '/admin/scoped/new'
    assert_includes post_form('/admin/scoped', scoped_params('none')).body, 'Add at least one grant.'
  ensure
    ENV.delete('MCP_BASE_URL')
  end

  def test_edit_a_scoped_token
    commit_file('Inbox/.keep', '')
    Vault.create('work')
    token, secret = Devices.create_scoped(name: 'claude', grants: [{ vault: 'test', folder: 'Inbox', mode: 'w' },
                                                                    { vault: 'test', folder: 'Gone', mode: 'r' }])
    login
    get "/admin/scoped/#{token.id}"
    assert_equal 200, last_response.status
    assert_equal 1, last_response.body.scan('folder missing').size
    assert_includes last_response.body, 'value="Gone"'

    # Renamed, Gone removed, a grant in another vault, a nested one that adds
    res = post_form("/admin/scoped/#{token.id}", scoped_params('claude-ai', %w[test Inbox w], %w[test Inbox/Sub r], %w[work Notes rw]))
    assert_equal '/admin/scoped', res['Location']
    assert_equal 'claude-ai', Devices.authenticate(secret, kind: 'scoped').first.name
    assert_equal [%w[test Inbox w], %w[test Inbox/Sub r], %w[work Notes rw]], grants_of(token.id)

    # Errors on their rows; nothing saved, the name neither
    get "/admin/scoped/#{token.id}"
    res = post_form("/admin/scoped/#{token.id}", scoped_params('renamed', %w[test Inbox w], %w[test Inbox r], %w[test .hidden w],
                                                              %w[test Inbox/Sub w]))
    assert_equal 422, res.status
    assert_includes res.body, '`Inbox` is in test twice.'
    assert_includes res.body, '`.hidden` can&#39;t be granted'
    assert_includes res.body, '`w` on Inbox/Sub has no effect: Inbox already gives w.'
    assert_equal 3, res.body.scan('class="row-error"').size
    assert_equal 'claude-ai', DB[:devices].where(id: token.id).get(:name)
    assert_equal 3, grants_of(token.id).size

    get "/admin/scoped/#{token.id}"
    res = post_form("/admin/scoped/#{token.id}", scoped_params('Bad Name', %w[test Inbox w]))
    assert_equal 422, res.status
    assert_includes res.body, 'bad name'
    assert_equal 3, grants_of(token.id).size, 'grants neither'

    device = DB[:devices].where(name: 'test-device').get(:id)
    get "/admin/scoped/#{device}"
    assert_equal 404, last_response.status, 'a device token has no page here'
    get "/admin/scoped/#{token.id}"
    assert_equal 404, post_form("/admin/scoped/#{device}", scoped_params('renamed', %w[test Inbox w])).status
    assert_equal 'test-device', DB[:devices].where(id: device).get(:name)
  end

  # The whole vault: an empty folder (or /), the new row's default
  # A grant's purpose: folded under its row (details), its first line shown; open by itself only when it's too long
  def test_purposes
    login
    get '/admin/scoped/new'
    assert_includes last_response.body, '<span class="add">Add purpose</span>'
    res = post_form('/admin/scoped', scoped_params('claude', ['test', 'Claude', 'rw', "  Memory mirror.\r\nOne note per memory. "],
                                                   %w[test Inbox w]))
    assert_equal 200, res.status
    token = DB[:devices].where(name: 'claude').get(:id)
    assert_equal ["Memory mirror.\nOne note per memory.", ''], Grants.of(token).map(&:purpose)

    get "/admin/scoped/#{token}"
    assert_includes last_response.body, '<span class="label">Purpose</span><span class="preview"><span>Memory mirror.</span></span>'
    assert_includes last_response.body, "aria-label=\"Purpose\"\n                  placeholder=\"Claude sees this: what the folder is for, how to use it\">Memory mirror.\nOne note per memory.</textarea>"
    refute_includes last_response.body, '<details open>'

    res = post_form("/admin/scoped/#{token}", scoped_params('claude', ['test', 'Claude', 'rw', 'x' * 2001]))
    assert_equal 422, res.status
    assert_includes res.body, 'The purpose is 2001 characters, at most 2000.'
    assert_equal 1, res.body.scan('<details open>').size
    assert_equal 'Memory mirror.', Grants.of(token).first.purpose.lines.first.chomp, 'nothing saved'
  end

  def test_a_whole_vault_grant
    login
    get '/admin/scoped/new'
    assert_includes last_response.body, 'name="grants[0][folder]" value=""'
    res = post_form('/admin/scoped', scoped_params('claude', ['test', '/', 'w']))
    assert_equal 200, res.status
    token = DB[:devices].where(name: 'claude').get(:id)
    assert_equal [['test', '', 'w']], grants_of(token)
    get '/admin/scoped'
    assert_includes last_response.body, 'test:/ (w)'
    refute_includes last_response.body, 'check grants'
  end

  # Grants saved before a check could refuse them (a folder renamed under another grant): marked in the list, errors
  # on the page
  def test_grants_that_no_longer_pass_are_marked
    token, = Devices.create_scoped(name: 'claude')
    Grants.replace(token.id, [{ vault: 'test', folder: '', mode: 'w' }, { vault: 'test', folder: 'Inbox', mode: 'w' }])
    Devices.create_scoped(name: 'fine', grants: [{ vault: 'test', folder: 'Inbox', mode: 'w' }])
    login
    get '/admin/scoped'
    assert_equal 1, last_response.body.scan('check grants').size
    assert_includes last_response.body, 'test:/ (w) <span class="muted">+1</span>'
    get "/admin/scoped/#{token.id}"
    assert_includes last_response.body, '`w` on Inbox has no effect: / already gives w.'
  end

  def test_revoke_a_scoped_token
    token, secret = Devices.create_scoped(name: 'claude', grants: [{ vault: 'test', folder: 'Inbox', mode: 'w' }])
    gone, = Devices.create_scoped(name: 'gone', grants: [{ vault: 'test', folder: 'Inbox', mode: 'r' }])
    Devices.revoke(gone.id)
    login
    get '/admin/scoped'
    assert_includes last_response.body, 'claude'
    refute_includes last_response.body, 'gone'
    refute_includes last_response.body, 'Revoke', 'not in the list'
    get '/admin/scoped?revoked=1'
    assert_includes last_response.body, %(<tr class="link revoked">\n              <td><a href="/admin/scoped/#{gone.id}">gone</a>)
    assert_includes last_response.body, 'name="revoked" value="1" checked'

    get "/admin/scoped/#{token.id}"
    assert_includes last_response.body, 'data-confirm="Revoke claude?'
    assert_equal "/admin/scoped/#{token.id}", post_form("/admin/scoped/#{token.id}/revoke")['Location']
    assert_equal [nil, :revoked], Devices.authenticate(secret, kind: 'scoped')

    get "/admin/scoped/#{token.id}"
    refute_includes last_response.body, 'name="grants['
    refute_includes last_response.body, '>Revoke<'
    assert_includes last_response.body, 'Revoked'
    assert_equal "/admin/scoped/#{token.id}", post_form("/admin/scoped/#{token.id}", scoped_params('renamed', %w[test Notes rw]))['Location']
    assert_equal [%w[test Inbox w]], grants_of(token.id), 'read-only'
    assert_equal 'claude', DB[:devices].where(id: token.id).get(:name)
  end

  def test_revoke
    login
    get '/admin/'
    id = DB[:devices].where(name: 'test-device').get(:id)
    assert_equal '/admin/tokens', post_form("/admin/tokens/#{id}/revoke")['Location']
    get '/admin/tokens?revoked=1'
    assert_includes last_response.body, '<tr class="revoked">'

    basic_authorize('test', @token)
    get '/manifest'
    assert_equal 401, last_response.status
  end
end
