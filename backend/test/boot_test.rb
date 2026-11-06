require_relative 'test_helper'
require 'open3'
require 'rbconfig'

# config.ru in a process of its own: what the server does at boot. Run in the temp dir, so dotenv finds no .env files
class BootTest < VaultTest
  CONFIG_RU = File.expand_path('../config.ru', __dir__)
  ADMIN_ENV = Config::ADMIN_ENV.to_h { [_1, nil] }
  INIT_ENV = Config::INIT_ENV.to_h { [_1, nil] }
  # Unset: ENABLED_APPS' default (sync)
  APPS_ENV = { 'ENABLED_APPS' => nil, 'MCP_ENABLED' => nil }.freeze

  # Boots config.ru, then sends each request (method, path — as is, `..` and all —, Basic credentials): [output, exit
  # status, statuses]. Each request's line: `status=<code> bytes=<body size>`
  def boot(env = {}, requests = [])
    script = <<~RUBY
      app = Rack::Builder.parse_file(#{CONFIG_RU.inspect})
      #{requests.inspect}.each do |verb, path, auth|
        env = Rack::MockRequest.env_for(path, method: verb)
        env['HTTP_AUTHORIZATION'] = "Basic \#{[auth].pack('m0')}" if auth
        status, _, body = app.call(env)
        bytes = 0
        body.each { bytes += _1.bytesize }
        warn "status=\#{status} bytes=\#{bytes}"
      end
    RUBY
    env = { 'VAULTS_DIR' => @vaults_dir, 'DB_DIR' => ENV['DB_DIR'], 'RACK_ENV' => 'development' }
          .merge(ADMIN_ENV, INIT_ENV, APPS_ENV, env)
    output, status = Open3.capture2e(env, RbConfig.ruby, '-rbundler/setup', '-rrack', '-e', script, chdir: @root)
    [output, status.exitstatus, output.scan(/^status=(\d+) /).flatten.map(&:to_i)]
  end

  def test_boots
    output, code, = boot
    assert_equal 0, code, output
  end

  def test_requests_are_logged_only_with_verbose_http_logs
    [nil, '', 'false', '0'].each do |off|
      output, code, statuses = boot({ 'VERBOSE_HTTP_LOGS' => off }, [['GET', '/vaults']])
      assert_equal 0, code, output
      assert_equal [401], statuses
      refute_match(/^(<--|-->) /, output)
    end

    %w[true 1].each do |on|
      output, code, statuses = boot({ 'VERBOSE_HTTP_LOGS' => on }, [['GET', '/vaults']])
      assert_equal 0, code, output
      assert_equal [401], statuses
      assert_includes output, '<-- GET '
      assert_includes output, '--> 401 unauthorized: no Basic credentials'
    end
  end

  def test_a_vault_without_its_repo_stops_the_boot
    FileUtils.rm_rf(File.join(@vaults_dir, 'test', 'repo.git'))
    output, code, = boot
    assert_equal 1, code
    assert_equal "vault-sync: not starting: vault test missing: no #{@vaults_dir}/test/repo.git\n", output
  end

  # /config not mounted: not a fresh install
  def test_a_missing_database_directory_stops_the_boot
    missing = File.join(@root, 'db')
    output, code, = boot('DB_DIR' => missing)
    assert_equal 1, code
    assert_equal "vault-sync: not starting: database directory missing: #{missing} (not mounted?)\n", output
    refute Dir.exist?(missing)
  end

  def test_a_missing_vaults_directory_stops_the_boot
    missing = File.join(@root, 'elsewhere')
    output, code, = boot('VAULTS_DIR' => missing)
    assert_equal 1, code
    assert_equal "vault-sync: not starting: vaults directory missing: #{missing} (not mounted?)\n", output
    refute Dir.exist?(missing)
  end

  def test_a_missing_database_file_is_created
    dir = File.join(@root, 'fresh')
    Dir.mkdir(dir)
    _, code, = boot('DB_DIR' => dir)
    assert_equal 0, code
    assert File.exist?(File.join(dir, 'vault-sync.db'))
  end

  INIT_CODE = '482913'

  def pair_status(code)
    Pairings::ATTEMPTS.reset
    Rack::MockRequest.new(App).post('/pair', input: JSON.generate(code:, name: 'pixel'), 'CONTENT_TYPE' => 'application/json')
  end

  def test_init_env_makes_a_vault_and_a_code_for_its_first_device
    env = { 'INIT_VAULT_NAME' => 'notes', 'INIT_VAULT_CODE' => INIT_CODE }
    output, code, = boot(env)
    assert_equal 0, code, output
    assert_includes output, "vault-sync: vault notes created\n"
    assert_includes output, "vault-sync: INIT_VAULT_CODE: open for the first device of notes\n"
    refute_includes output, INIT_CODE

    res = pair_status(INIT_CODE)
    assert_equal 200, res.status
    assert_equal 'notes', JSON.parse(res.body)['vault']

    output, code, = boot(env)
    assert_equal 0, code, output
    refute_includes output, 'created'
    assert_includes output, 'INIT_VAULT_CODE: ignored, notes has its devices already'
    assert_equal 401, pair_status(INIT_CODE).status, 'used once, gone for good'
  end

  # Storage not mounted: the database knows a vault whose repo isn't there, nothing gets created in its place
  def test_init_env_never_runs_past_a_missing_repo
    FileUtils.rm_rf(File.join(@vaults_dir, 'test', 'repo.git'))
    output, code, = boot('INIT_VAULT_NAME' => 'test', 'INIT_VAULT_CODE' => INIT_CODE)
    assert_equal 1, code
    assert_includes output, 'vault test missing'
    refute Dir.exist?(File.join(@vaults_dir, 'test', 'repo.git'))
    assert_empty DB[:pairings]
  end

  def test_init_code_needs_a_vault
    output, code, = boot('INIT_VAULT_CODE' => INIT_CODE)
    assert_equal 1, code
    assert_includes output, 'INIT_VAULT_NAME'
    refute_includes output, INIT_CODE
  end

  # Named, never shown
  def test_a_bad_init_code_stops_the_boot
    %w[12345 1234567 abcdef].each do |bad|
      output, code, = boot('INIT_VAULT_NAME' => 'notes', 'INIT_VAULT_CODE' => bad)
      assert_equal 1, code, bad
      assert_match(/\Avault-sync: not starting: INIT_VAULT_CODE must be 6 digits/, output)
      refute_includes output, bad
    end
    refute Dir.exist?(File.join(@vaults_dir, 'notes'))
  end

  def test_init_vault_alone
    output, code, = boot('INIT_VAULT_NAME' => 'notes')
    assert_equal 0, code, output
    assert Dir.exist?(File.join(@vaults_dir, 'notes', 'repo.git'))
  end

  def admin_env = Config::ADMIN_ENV.to_h { [_1, ENV.fetch(_1)] }.merge('ENABLED_APPS' => 'sync,admin')

  def test_admin_mounted_with_its_env
    output, code, statuses = boot(admin_env, [['GET', '/admin/']])
    assert_equal 0, code, output
    assert_includes output, "vault-sync: serving sync, admin\n"
    assert_equal [302], statuses
  end

  # Not there at all: /admin is one more unknown App route (401 without credentials, 404 with)
  def test_no_admin_unless_enabled
    output, code, statuses = boot({}, [['GET', '/admin/'], ['GET', '/admin/', "test:#{@token}"]])
    assert_equal 0, code, output
    assert_includes output, "vault-sync: serving sync\n"
    refute_includes output, 'admin env'
    assert_equal [401, 404], statuses
  end

  # Not there at all: /mcp is one more unknown App route, a device token gets its 404
  def test_no_mcp_unless_enabled
    output, code, statuses = boot({}, [['POST', '/mcp'], ['POST', '/mcp', "test:#{@token}"]])
    assert_equal 0, code, output
    assert_equal [401, 404], statuses
  end

  def test_mcp_mounted_when_enabled
    output, code, statuses = boot({ 'ENABLED_APPS' => 'sync,mcp' }, [['POST', '/mcp', "test:#{@token}"]])
    assert_equal 0, code, output
    assert_includes output, "vault-sync: serving sync, mcp\n"
    assert_equal [401], statuses, 'the endpoint refuses a device token'
  end

  # Which app answers: /health (every process), Admin's login page (200; else App's 401 or the empty 404), McpEndpoint
  # refusing a device token (401; else App's 404 for the unknown route or the empty 404), App's /vaults (200; else 404)
  APP_PROBES = [%w[GET /health], %w[GET /admin/login], %w[POST /mcp device], %w[GET /vaults device]].freeze
  APP_ANSWERS = {
    'sync' => [200, 401, 404, 200],
    'mcp' => [200, 404, 401, 404],
    'admin' => [200, 200, 404, 404],
    'sync,mcp' => [200, 401, 401, 200],
    'mcp,admin' => [200, 200, 401, 404],
    'sync, mcp , admin' => [200, 200, 401, 200]
  }.freeze

  def test_each_combination_mounts_exactly_its_apps
    probes = APP_PROBES.map { |verb, path, auth| [verb, path, auth && "test:#{@token}"] }
    APP_ANSWERS.each do |apps, answers|
      output, code, statuses = boot(admin_env.merge('ENABLED_APPS' => apps), probes)
      assert_equal 0, code, output
      assert_includes output, "vault-sync: serving #{apps.split(',').map(&:strip).join(', ')}\n"
      assert_equal answers, statuses, apps
    end
  end

  # Without sync: what isn't there is the empty 404 of any unknown path, /pair and the sync API included
  def test_without_sync_anything_unknown_is_an_empty_404
    paths = ['/pair', '/files/a.md', '/manifest', '/admin/login', '/vaults', '/nothing', '/health/x']
    output, code, statuses = boot({ 'ENABLED_APPS' => 'mcp' }, paths.map { ['GET', _1] } + [%w[POST /health]])
    assert_equal 0, code, output
    assert_equal [404] * 8, statuses
    assert_equal ['0'] * 8, output.scan(/ bytes=(\d+)$/).flatten
  end

  # The review's way into /admin through a proxy allowing /files/: CanonicalPath refuses the non-canonical forms (400)
  # before any app; the canonical one finds no Admin in a process without admin. (`//admin/login` is sent raw in
  # processes_test.rb: Rack::MockRequest would read `//admin` as a host)
  def test_admin_paths_reach_nothing_without_admin
    paths = ['/admin/../files/a%2f..%2f..%2flogin', '/admin//login', '/admin/./login', '/admin/login']
    output, code, statuses = boot(admin_env.merge('ENABLED_APPS' => 'sync,mcp'), paths.map { ['GET', _1] })
    assert_equal 0, code, output
    assert_equal [400, 400, 400, 401], statuses
    output, code, statuses = boot(admin_env.merge('ENABLED_APPS' => 'mcp'), paths.map { ['GET', _1] })
    assert_equal 0, code, output
    assert_equal [400, 400, 400, 404], statuses
  end

  def test_bad_enabled_apps_stop_the_boot
    ['', ' ', 'sinc', 'sync,', 'sync,,mcp', 'sync,secret-thing', 'sync;mcp'].each do |apps|
      output, code, = boot('ENABLED_APPS' => apps)
      assert_equal 1, code, apps
      assert_equal "vault-sync: not starting: ENABLED_APPS must list one or more of sync, mcp, admin, comma-separated\n",
                   output
    end
  end

  # Loud: an old setup would lose /mcp without a word
  def test_mcp_enabled_stops_the_boot
    %w[true 1 false].each do |value|
      output, code, = boot('MCP_ENABLED' => value, 'ENABLED_APPS' => 'sync,mcp')
      assert_equal 1, code, value
      assert_equal "vault-sync: not starting: MCP_ENABLED is gone: list mcp in ENABLED_APPS instead\n", output
    end
  end

  def test_admin_without_its_env_stops_the_boot
    output, code, = boot('ENABLED_APPS' => 'admin')
    assert_equal 1, code
    assert_equal "vault-sync: not starting: Environment variable `ADMIN_USER`, `ADMIN_PASSWORD`, `SESSION_SECRET` must be defined.\n",
                 output
  end

  # The admin's settings left in a process that doesn't serve it: said once, checked no further
  def test_admin_env_without_admin
    output, code, statuses = boot(admin_env.merge('ENABLED_APPS' => 'sync', 'SESSION_SECRET' => nil), [['GET', '/admin/login']])
    assert_equal 0, code, output
    assert_includes output, "vault-sync: admin env set, admin not enabled\n"
    refute_includes output, ENV.fetch('ADMIN_PASSWORD')
    assert_equal [401], statuses
  end

  # INIT_* is acted on only where /pair is: checked anywhere
  def test_init_env_only_where_sync_runs
    output, code, = boot('ENABLED_APPS' => 'mcp', 'INIT_VAULT_NAME' => 'notes', 'INIT_VAULT_CODE' => INIT_CODE)
    assert_equal 0, code, output
    refute_includes output, 'notes'
    refute Dir.exist?(File.join(@vaults_dir, 'notes'))
    assert_empty DB[:pairings]

    output, code, = boot('ENABLED_APPS' => 'mcp', 'INIT_VAULT_NAME' => 'notes', 'INIT_VAULT_CODE' => '123')
    assert_equal 1, code
    assert_includes output, 'INIT_VAULT_CODE must be 6 digits'
  end

  def test_admin_without_totp
    output, code, statuses = boot(admin_env.merge('ADMIN_TOTP_SECRET' => nil), [['GET', '/admin/login']])
    assert_equal 0, code, output
    assert_includes output, "vault-sync: admin without TOTP, the password alone protects it\n"
    assert_equal [200], statuses
  end

  def test_a_totp_secret_alone_is_not_an_admin_env
    output, code, = boot('ADMIN_TOTP_SECRET' => ENV.fetch('ADMIN_TOTP_SECRET'), 'ENABLED_APPS' => 'admin')
    assert_equal 1, code
    assert_includes output, 'ADMIN_USER'
    refute_includes output, ENV.fetch('ADMIN_TOTP_SECRET')
  end

  def test_partial_admin_env_stops_the_boot
    output, code, = boot(admin_env.merge('ADMIN_PASSWORD' => nil, 'SESSION_SECRET' => ''))
    assert_equal 1, code
    assert_equal "vault-sync: not starting: Environment variable `ADMIN_PASSWORD`, `SESSION_SECRET` must be defined.\n", output
  end

  def test_the_admin_panel_needs_a_public_url
    output, code, = boot(admin_env.merge('PUBLIC_URL' => nil))
    assert_equal 1, code
    assert_equal "vault-sync: not starting: Environment variable `PUBLIC_URL` must be defined.\n", output

    ['notes.example.com', 'ftp://notes.example.com', 'https://', 'https://notes.example.com/?a=1', 'not a url'].each do |url|
      output, code, = boot(admin_env.merge('PUBLIC_URL' => url))
      assert_equal 1, code, url
      assert_equal "vault-sync: not starting: PUBLIC_URL must be the http(s) address devices reach this server at\n", output
    end

    ['https://notes.example.com/', 'http://localhost:9292', 'https://example.com/sync'].each do |url|
      output, code, = boot(admin_env.merge('PUBLIC_URL' => url))
      assert_equal 0, code, output
    end
  end

  def test_no_admin_panel_no_public_url_needed
    output, code, = boot('PUBLIC_URL' => nil)
    assert_equal 0, code, output
  end

  # Named, never shown
  def test_invalid_admin_env_stops_the_boot
    { 'ADMIN_TOTP_SECRET' => 'not base32!', 'SESSION_SECRET' => 'short' }.each do |var, value|
      output, code, = boot(admin_env.merge(var => value))
      assert_equal 1, code, var
      assert_match(/\Avault-sync: not starting: #{var} must be/, output)
      refute_includes output, value
    end
    output, code, = boot(admin_env.merge('ADMIN_TOTP_SECRET' => 'JBSWY3DP')) # 40 bits
    assert_equal 1, code
    assert_includes output, 'ADMIN_TOTP_SECRET must be base32, at least 128 bits'
  end
end
