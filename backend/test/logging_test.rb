require_relative 'test_helper'
require 'json'
require 'stringio'

# VERBOSE_HTTP_LOGS (config.ru's LogRequestAndResponse, on in tests): no credential header and no file content in a log
# line, whatever the route; JSON answers only for the routes that carry neither
class LoggingTest < VaultTest
  CREDENTIALS = {
    'HTTP_COOKIE' => 'session=cookie-secret',
    'HTTP_PROXY_AUTHORIZATION' => 'Basic proxy-secret',
    'HTTP_CF_ACCESS_CLIENT_ID' => 'cf-client-id.access',
    'HTTP_CF_ACCESS_CLIENT_SECRET' => 'cf-client-secret',
    'HTTP_CF_ACCESS_JWT_ASSERTION' => 'cf-jwt-assertion',
    'HTTP_X_API_KEY' => 'api-key-secret',
    'HTTP_X_AUTH_TOKEN' => 'auth-token-secret'
  }.freeze

  def auth(vault = 'test', token = @token) = { 'HTTP_AUTHORIZATION' => "Basic #{["#{vault}:#{token}"].pack('m0')}" }

  # Requests through config.ru: their log lines
  def logged
    capture_io { yield Rack::MockRequest.new(config_ru) }.first
  end

  def assert_nothing_secret(log)
    [@token, *CREDENTIALS.values].each { refute_includes log, _1 }
  end

  def test_no_credentials_and_no_content
    commit_file('Canvas/board.canvas', '{"nodes":[{"text":"canvas secret"}]}')
    commit_file('data.json', '{"note":"json secret"}')
    commit_file('Private/hidden name.md', "x\n")
    log = logged do |client|
      res = client.get('/files/data.json', **auth, **CREDENTIALS, 'HTTP_X_ROCK_SYNC_CLIENT' => 'plugin=1.0.1')
      assert_equal '{"note":"json secret"}', res.body
      assert_includes client.get('/files/Canvas/board.canvas', **auth, **CREDENTIALS).body, 'canvas secret'
      merged = client.post('/merge/data.json', input: '{"note":"mine"}', 'CONTENT_TYPE' => 'text/plain',
                                               'HTTP_IF_MATCH' => blob('{"note":"json secret"}'), **auth)
      assert_equal 200, merged.status
      assert_includes client.get('/manifest?v=1', **auth).body, 'hidden name'
      client.get('/manifest?v=1', **auth('test', 'x' * 43), **CREDENTIALS) # refused
    end
    assert_nothing_secret(log)
    %w[json\ secret canvas\ secret mine hidden\ name].each { refute_includes log, _1 }
    assert_includes log, '"X-Rock-Sync-Client" => "plugin=1.0.1"' # other headers still there
    assert_includes log, '--> 200 device=test-device vault=test "- stripped -"'
    assert_includes log, '--> 401 unauthorized: unknown token "- stripped -"'
  end

  def test_answers_without_content_are_logged
    log = logged { |client| assert_equal 200, client.get('/vaults', **auth('', @token), **CREDENTIALS).status }
    assert_nothing_secret(log)
    assert_includes log, %(--> 200 device=test-device {"vaults" => ["test"]})
  end
end
