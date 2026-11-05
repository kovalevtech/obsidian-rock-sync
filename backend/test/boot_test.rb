require_relative 'test_helper'
require 'open3'
require 'rbconfig'

# config.ru in a process of its own: what the server does at boot. Run in the temp dir, so dotenv finds no .env files
class BootTest < VaultTest
  CONFIG_RU = File.expand_path('../config.ru', __dir__)
  ADMIN_ENV = Config::ADMIN_ENV.to_h { [_1, nil] }
  INIT_ENV = Config::INIT_ENV.to_h { [_1, nil] }
  MCP_OFF = { 'MCP_ENABLED' => nil }.freeze

  # Boots config.ru, then sends each request (method, path, Basic credentials): [output, exit status, statuses]
  def boot(env = {}, requests = [])
    script = <<~RUBY
      app = Rack::Builder.parse_file(#{CONFIG_RU.inspect})
      #{requests.inspect}.each do |verb, path, auth|
        env = Rack::MockRequest.env_for(path, method: verb)
        env['HTTP_AUTHORIZATION'] = "Basic \#{[auth].pack('m0')}" if auth
        warn "status=\#{app.call(env).first}"
      end
    RUBY
    env = { 'VAULTS_DIR' => @vaults_dir, 'DB_DIR' => ENV['DB_DIR'], 'RACK_ENV' => 'development' }
          .merge(ADMIN_ENV, INIT_ENV, MCP_OFF, env)
    output, status = Open3.capture2e(env, RbConfig.ruby, '-rbundler/setup', '-rrack', '-e', script, chdir: @root)
    [output, status.exitstatus, output.scan(/^status=(\d+)$/).flatten.map(&:to_i)]
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

  def admin_env = Config::ADMIN_ENV.to_h { [_1, ENV.fetch(_1)] }

  def test_admin_mounted_with_its_env
    output, code, statuses = boot(admin_env, [['GET', '/admin/']])
    assert_equal 0, code, output
    assert_equal [302], statuses
    refute_includes output, 'admin disabled'
  end

  # Not there at all: /admin is one more unknown App route (401 without credentials, 404 with)
  def test_no_admin_env_no_admin
    output, code, statuses = boot({}, [['GET', '/admin/'], ['GET', '/admin/', "test:#{@token}"]])
    assert_equal 0, code, output
    assert_includes output, "vault-sync: admin disabled\n"
    assert_equal [401, 404], statuses
  end

  # Not there at all: /mcp is one more unknown App route, a device token gets its 404
  def test_no_mcp_unless_enabled
    output, code, statuses = boot({}, [['POST', '/mcp'], ['POST', '/mcp', "test:#{@token}"]])
    assert_equal 0, code, output
    assert_includes output, "vault-sync: MCP disabled\n"
    assert_equal [401, 404], statuses
  end

  def test_mcp_mounted_when_enabled
    %w[true 1].each do |value|
      output, code, statuses = boot({ 'MCP_ENABLED' => value }, [['POST', '/mcp', "test:#{@token}"]])
      assert_equal 0, code, output
      refute_includes output, 'MCP disabled'
      assert_equal [401], statuses, 'the endpoint refuses a device token'
    end
  end

  def test_admin_without_totp
    output, code, statuses = boot(admin_env.merge('ADMIN_TOTP_SECRET' => nil), [['GET', '/admin/login']])
    assert_equal 0, code, output
    assert_includes output, "vault-sync: admin without TOTP, the password alone protects it\n"
    assert_equal [200], statuses
  end

  def test_a_totp_secret_alone_is_not_an_admin_env
    output, code, = boot('ADMIN_TOTP_SECRET' => ENV.fetch('ADMIN_TOTP_SECRET'))
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
