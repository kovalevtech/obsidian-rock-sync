# frozen_string_literal: false
# Auth over HTTP: every route is closed without the right vault + token, a token never reaches another vault, and
# commits name the token's device
require_relative 'test_helper'
require 'json'

class AuthTest < VaultTest
  include Rack::Test::Methods

  def app = App

  def setup
    super
    @other = Vault.create('other')
    @other_token = add_token('other-device', 'other')
    @revoked_token = add_token('old-device', 'test')
    Devices.revoke(DB[:devices].where(name: 'old-device').get(:id))
  end

  def basic(vault, token) = "Basic #{["#{vault}:#{token}"].pack('m0')}"

  # Every route Sinatra knows (HEAD included), with a concrete path, plus one it doesn't; App::PUBLIC left out.
  # DELETE /token last: it revokes the token
  def routes
    App.routes.flat_map { |verb, list| list.map { |pattern, *| [verb, pattern.to_s.gsub('*', 'a.md')] } }
      .reject { |_, path| App::PUBLIC.include?(path) }
      .push(%w[GET /nope])
      .sort_by { |verb, path| [verb, path] == %w[DELETE /token] ? 1 : 0 }
  end

  def test_unknown_routes_are_404_with_credentials
    assert_equal 404, call('GET', '/nope', basic('test', @token)).status
  end

  # Routes naming a vault: App::DEVICE_ONLY ones ignore the vault part
  def vault_routes = routes.reject { |_, path| App::DEVICE_ONLY.include?(path) }

  def call(verb, path, authorization, env = {})
    env = env.merge('HTTP_AUTHORIZATION' => authorization) if authorization
    custom_request(verb, path, "x\n", { 'HTTP_DESTINATION' => 'b.md' }.merge(env))
    last_response
  end

  # { path => content } of a vault's tree (nil for directories)
  def snapshot(vault)
    Dir.glob('**/*', base: vault.tree).to_h { |rel| [rel, (File.binread(vault.file(rel)) if File.file?(vault.file(rel)))] }
  end

  def assert_unauthorized(res, what)
    assert_equal 401, res.status, what
    assert_nil res['WWW-Authenticate'], what
    assert_equal '{"error":"unauthorized"}', res.body, what unless what.start_with?('HEAD')
  end

  def test_every_route_denies_by_default
    denied = {
      'no header' => nil,
      'not Basic' => "Bearer #{@token}",
      'not base64' => 'Basic !!!',
      'no colon' => "Basic #{[@token].pack('m0')}",
      'bad token' => basic('test', 'x' * 43),
      'revoked token' => basic('test', @revoked_token)
    }
    wrong_vault = {
      "another vault's token" => basic('test', @other_token),
      'vault not in the database' => basic('missing', @token),
      'no vault' => basic('', @token)
    }
    routes.each do |verb, path|
      denied.each { |why, header| assert_unauthorized(call(verb, path, header), "#{verb} #{path}: #{why}") }
    end
    vault_routes.each do |verb, path|
      wrong_vault.each { |why, header| assert_unauthorized(call(verb, path, header), "#{verb} #{path}: #{why}") }
    end
    assert_equal 0, commit_count
  end

  def test_valid_credentials_reach_every_route
    routes.each do |verb, path|
      refute_equal 401, call(verb, path, basic('test', @token)).status, "#{verb} #{path}"
    end
  end

  # The token's own vaults, whatever the vault part says; never another token's
  def test_vaults_lists_the_tokens_vaults
    ['', 'test', 'other', 'missing'].each do |vault|
      res = call('GET', '/vaults', basic(vault, @token))
      assert_equal 200, res.status, vault
      assert_equal({ 'vaults' => ['test'] }, JSON.parse(res.body), vault)
    end
    assert_equal({ 'vaults' => ['other'] }, JSON.parse(call('GET', '/vaults', basic('', @other_token)).body))
  end

  def test_vaults_leaves_out_a_vault_without_its_repo
    FileUtils.rm_rf(File.join(@vaults_dir, 'other', 'repo.git'))
    assert_equal({ 'vaults' => [] }, JSON.parse(call('GET', '/vaults', basic('', @other_token)).body))
  end

  # Same 401 as an unknown token; only the log knows
  def test_a_revoked_token_is_any_other_failure
    unknown = call('GET', '/manifest', basic('test', 'x' * 43))
    revoked = call('GET', '/manifest', basic('test', @revoked_token))
    assert_equal [unknown.status, unknown.headers.to_h, unknown.body], [revoked.status, revoked.headers.to_h, revoked.body]
    assert_equal 'unauthorized: revoked token', last_request.env['vault_sync.auth']
  end

  def test_a_vault_without_its_repo_is_closed
    FileUtils.rm_rf(File.join(@vaults_dir, 'other', 'repo.git'))
    assert_unauthorized(call('GET', '/manifest', basic('other', @other_token)), 'repo gone')
  end

  def test_requests_mark_the_device_seen
    assert_nil DB[:devices].where(name: 'test-device').get(:last_seen_at)
    assert_equal 200, call('GET', '/manifest', basic('test', @token)).status
    assert_in_delta Time.now, DB[:devices].where(name: 'test-device').get(:last_seen_at), 5
  end

  def test_health_answers_without_credentials
    %w[GET HEAD].each do |verb|
      res = call(verb, '/health', nil)
      assert_equal 200, res.status, verb
      assert_nil res['WWW-Authenticate'], verb
    end
    assert_equal 'ok', call('GET', '/health', nil).body
    assert_equal 'ok', call('GET', '/health', basic('test', 'x' * 43)).body # a wrong token changes nothing
    assert_equal 404, call('POST', '/health', nil).status
  end

  def test_auth_before_the_size_limit
    ENV['MAX_FILE_SIZE'] = '1'
    assert_unauthorized(call('PUT', '/files/a.md', nil), 'no header')
  ensure
    ENV.delete('MAX_FILE_SIZE')
  end

  def test_a_token_never_reaches_another_vault
    WriteFile.call(@other, 'a.md', "b's\n", if_none_match: '*')
    head = @other.version
    tree = snapshot(@other)

    vault_routes.each do |verb, path|
      assert_unauthorized(call(verb, path, basic('other', @token)), "#{verb} #{path}")
    end
    get '/manifest', { 'wait' => '1' }, 'HTTP_AUTHORIZATION' => basic('other', @token), 'HTTP_IF_NONE_MATCH' => %("#{head}")
    assert_unauthorized(last_response, 'long poll')

    assert_equal head, @other.version
    assert_equal tree, snapshot(@other)
    assert_equal 0, commit_count
  end

  def test_each_token_writes_its_own_vault
    assert_equal 204, call('PUT', '/files/a.md', basic('test', @token)).status
    assert_equal 204, call('PUT', '/files/b.md', basic('other', @other_token)).status
    assert_equal ['a.md'], Dir.children(@vault.tree)
    assert_equal ['b.md'], Dir.children(@other.tree)
  end

  def test_commit_author_and_client_trailer
    put '/files/a.md', "a\n", 'HTTP_AUTHORIZATION' => basic('test', @token),
                              'HTTP_X_ROCK_SYNC_CLIENT' => 'plugin=1.2.0; obsidian=1.11.4; platform=android'
    assert_equal 204, last_response.status
    assert_equal "test-device <test-device@device>\nsync <sync@localhost>\n" \
                 "PUT a.md\n\nClient: plugin=1.2.0; obsidian=1.11.4; platform=android\n",
                 git('log', '-1', '--format=%an <%ae>%n%cn <%ce>%n%B').sub(/\n+\z/, "\n")
  end

  def test_client_header_is_one_printable_line_at_most_200_chars
    put '/files/a.md', "a\n", 'HTTP_AUTHORIZATION' => basic('test', @token),
                              'HTTP_X_ROCK_SYNC_CLIENT' => "plugin=1\r\nSigned-off-by: x\tё#{'y' * 300}"
    body = git('log', '-1', '--format=%B').chomp.chomp
    assert_equal "PUT a.md\n\nClient: #{"plugin=1Signed-off-by: x#{'y' * 300}"[0, 200]}", body
  end

  def test_no_trailer_without_client_header
    put '/files/a.md', "a\n", 'HTTP_AUTHORIZATION' => basic('test', @token)
    assert_equal "PUT a.md\n", git('log', '-1', '--format=%B').sub(/\n+\z/, "\n")
  end

  def test_long_poll_ignores_commits_in_other_vaults
    put '/files/a.md', "a\n", 'HTTP_AUTHORIZATION' => basic('test', @token)
    etag = (get '/manifest', {}, 'HTTP_AUTHORIZATION' => basic('test', @token))['ETag']
    poller = Thread.new do
      session = Rack::Test::Session.new(App)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      session.get '/manifest', { 'wait' => '1' }, 'HTTP_IF_NONE_MATCH' => etag, 'HTTP_AUTHORIZATION' => basic('test', @token)
      [session.last_response, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end
    sleep 0.3
    assert_equal 204, call('PUT', '/files/b.md', basic('other', @other_token)).status
    res, took = poller.value
    assert_equal 304, res.status
    assert_operator took, :>=, 0.9
  end
end
