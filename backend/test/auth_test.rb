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

  # A body with the plugin's content type (rack-test's default would be a form: 415)
  def call(verb, path, authorization, env = {})
    env = env.merge('HTTP_AUTHORIZATION' => authorization) if authorization
    custom_request(verb, path, "x\n", { 'HTTP_DESTINATION' => 'b.md', 'CONTENT_TYPE' => 'application/octet-stream',
                                        **env })
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
    # X-Rock-Sync-Vault naming the token's own vault opens nothing by itself
    headers = { 'no vault header' => {}, 'vault header' => { 'HTTP_X_ROCK_SYNC_VAULT' => 'test' } }
    routes.each do |verb, path|
      denied.to_a.product(headers.to_a).each do |(why, header), (how, env)|
        assert_unauthorized(call(verb, path, header, env), "#{verb} #{path}: #{why}, #{how}")
      end
    end
    vault_routes.each do |verb, path|
      wrong_vault.each { |why, header| assert_unauthorized(call(verb, path, header), "#{verb} #{path}: #{why}") }
    end
    # DEVICE_ONLY routes included: they ignore Basic's vault part, not the header
    routes.each do |verb, path|
      res = call(verb, path, basic('test', @token), 'HTTP_X_ROCK_SYNC_VAULT' => 'other')
      assert_unauthorized(res, "#{verb} #{path}: vault header mismatch")
    end
    assert_equal 0, commit_count
    assert Devices.authenticate(@token).first, 'DELETE /token refused'
  end

  # A method no route has, on a path that has routes: the same 401 without a token
  def test_unknown_methods_on_known_paths_deny_by_default
    routes.map(&:last).uniq.product(%w[PATCH OPTIONS]).each do |path, verb|
      assert_unauthorized(call(verb, path, nil), "#{verb} #{path}")
    end
  end

  def test_valid_credentials_reach_every_route
    routes.each do |verb, path|
      refute_equal 401, call(verb, path, basic('test', @token)).status, "#{verb} #{path}"
    end
  end

  # X-Rock-Sync-Vault: Basic's vault in the clear (a proxy filters by it); it must equal Basic's, else the usual 401
  def test_vault_header_equal_to_basics_vault
    assert_equal 200, call('GET', '/manifest', basic('test', @token), 'HTTP_X_ROCK_SYNC_VAULT' => 'test').status
  end

  def test_vault_header_unequal_to_basics_vault
    ok = call('GET', '/manifest', basic('test', 'x' * 43))
    res = call('GET', '/manifest', basic('test', @token), 'HTTP_X_ROCK_SYNC_VAULT' => 'other')
    assert_unauthorized(res, 'mismatch')
    assert_equal [ok.status, ok.headers.to_h, ok.body], [res.status, res.headers.to_h, res.body]
    assert_equal 'unauthorized: vault header mismatch', last_request.env['vault_sync.auth']
    # exact: no case folding, no trimming
    ['TEST', ' test', 'test ', ''].each do |header|
      assert_unauthorized(call('GET', '/manifest', basic('test', @token), 'HTTP_X_ROCK_SYNC_VAULT' => header), header.inspect)
    end
  end

  def test_no_vault_header_as_before
    assert_equal 200, call('GET', '/manifest', basic('test', @token)).status
  end

  # DEVICE_ONLY routes ignore Basic's vault part, but the header, when sent, must be the token's vault: else a proxy
  # letting one vault through would let any token in to confirm itself (/vaults, with a vault name) or revoke itself
  def test_vaults_and_the_vault_header
    [nil, 'test'].each do |header|
      env = header ? { 'HTTP_X_ROCK_SYNC_VAULT' => header } : {}
      ['', 'test', 'other'].each do |vault|
        res = call('GET', '/vaults', basic(vault, @token), env)
        assert_equal [200, { 'vaults' => ['test'] }], [res.status, JSON.parse(res.body)], [header, vault].inspect
      end
    end
    ['', 'other', 'missing', 'TEST', 'test '].each do |header|
      res = call('GET', '/vaults', basic('test', @token), 'HTTP_X_ROCK_SYNC_VAULT' => header)
      assert_unauthorized(res, header.inspect)
      assert_equal 'unauthorized: vault header mismatch', last_request.env['vault_sync.auth']
    end
  end

  def test_token_and_the_vault_header
    ['', 'other', 'missing'].each do |header|
      assert_unauthorized(call('DELETE', '/token', basic('test', @token), 'HTTP_X_ROCK_SYNC_VAULT' => header), header)
      assert_equal 'unauthorized: vault header mismatch', last_request.env['vault_sync.auth']
    end
    assert Devices.authenticate(@token).first

    assert_equal 204, call('DELETE', '/token', basic('', @token), 'HTTP_X_ROCK_SYNC_VAULT' => 'test').status
    assert_equal :revoked, Devices.authenticate(@token).last
    assert_equal 204, call('DELETE', '/token', basic('', @other_token)).status # no header: as before
    assert_equal :revoked, Devices.authenticate(@other_token).last
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

  # Over Rack's params limit (4096): parsed, it was a 500 (QueryLimitError) before auth
  FORM = 'a=1&' * 5000
  MULTIPART = "--x\r\nContent-Disposition: form-data; name=\"f\"; filename=\"f.md\"\r\n\r\nform\r\n--x--\r\n"
  FORMS = {
    'form' => ['application/x-www-form-urlencoded', FORM],
    'multipart' => ['multipart/form-data; boundary=x', MULTIPART],
    'other multipart' => ['multipart/mixed; boundary=x', MULTIPART],
    'form, upper case' => ['Application/X-WWW-Form-Urlencoded; charset=utf-8', FORM]
  }.freeze

  # A form body: with its Content-Length, or chunked (an input without a size: no Content-Length, as before Puma
  # de-chunks it)
  def form_env(type, body, chunked:)
    return { 'CONTENT_TYPE' => type, input: body } unless chunked

    reader, writer = IO.pipe
    writer.write(body)
    writer.close
    { 'CONTENT_TYPE' => type, 'HTTP_TRANSFER_ENCODING' => 'chunked', input: reader }
  end

  # Neither the query parser nor the multipart one ran; the body wasn't read
  def assert_unparsed(what)
    env = last_request.env
    assert_equal [[], nil], [env['rack.request.form_pairs'], env['rack.request.form_vars']], "#{what}: parsed"
    assert_equal 0, env['rack.input'].pos, "#{what}: read" if env['rack.input'].is_a?(StringIO)
  end

  # Form and multipart bodies are never parsed: without a token the usual 401, with one 415; nothing written
  def test_form_bodies_are_refused_unparsed
    routes = [%w[PUT /files/a.md], %w[POST /merge/a.md], %w[POST /move/a.md], %w[DELETE /files/a.md], %w[GET /manifest]]
    FORMS.each do |what, (type, body)|
      [false, true].each do |chunked|
        how = "#{what}#{', chunked' if chunked}"
        routes.each do |verb, path|
          [nil, 'Bearer x', basic('test', 'x' * 43), basic('test', @revoked_token)].each do |header|
            res = call(verb, path, header, form_env(type, body, chunked:))
            assert_unauthorized(res, "#{verb} #{path}: #{how}, #{header.inspect}")
            assert_unparsed("#{verb} #{path}: #{how}")
          end
          assert_equal 415, call(verb, path, basic('test', @token), form_env(type, body, chunked:)).status,
                       "#{verb} #{path}: #{how}"
          assert_unparsed("#{verb} #{path}: #{how}")
        end
        # No credentials there: refused right away
        assert_equal 415, call('POST', '/pair', nil, form_env(type, body, chunked:)).status, "/pair: #{how}"
        assert_unparsed("/pair: #{how}")
      end
    end
    assert_equal 0, commit_count
    assert_empty Dir.children(@vault.tree)
  end

  # A form type on a request without a body (rack-test's default; maybe some HTTP stacks') changes nothing
  def test_a_form_type_without_a_body_passes
    form = { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded', input: '' }
    assert_equal 204, call('PUT', '/files/a.md', basic('test', @token)).status
    assert_equal 204, call('POST', '/move/a.md', basic('test', @token), form).status
    assert_equal 204, call('DELETE', '/files/b.md', basic('test', @token), 'HTTP_IF_MATCH' => blob("x\n"), **form).status
    assert_equal 204, call('DELETE', '/token', basic('', @token), form).status
  end

  # Without a content type a POST body counts as a form for Rack: not parsed either, the route reads it
  def test_a_post_without_a_content_type_is_not_parsed
    call('POST', '/pair', nil, 'CONTENT_TYPE' => nil, input: FORM)
    assert_equal 400, last_response.status # the route read it as JSON
    assert_equal [[], nil], [last_request.env['rack.request.form_pairs'], last_request.env['rack.request.form_vars']]
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
    put '/files/a.md', "a\n", 'CONTENT_TYPE' => 'text/markdown', 'HTTP_AUTHORIZATION' => basic('test', @token),
                              'HTTP_X_ROCK_SYNC_CLIENT' => 'plugin=1.2.0; obsidian=1.11.4; platform=android'
    assert_equal 204, last_response.status
    assert_equal "test-device <test-device@device>\nsync <sync@localhost>\n" \
                 "PUT a.md\n\nClient: plugin=1.2.0; obsidian=1.11.4; platform=android\n",
                 git('log', '-1', '--format=%an <%ae>%n%cn <%ce>%n%B').sub(/\n+\z/, "\n")
  end

  def test_client_header_is_one_printable_line_at_most_200_chars
    put '/files/a.md', "a\n", 'CONTENT_TYPE' => 'text/markdown', 'HTTP_AUTHORIZATION' => basic('test', @token),
                              'HTTP_X_ROCK_SYNC_CLIENT' => "plugin=1\r\nSigned-off-by: x\tё#{'y' * 300}"
    body = git('log', '-1', '--format=%B').chomp.chomp
    assert_equal "PUT a.md\n\nClient: #{"plugin=1Signed-off-by: x#{'y' * 300}"[0, 200]}", body
  end

  def test_no_trailer_without_client_header
    put '/files/a.md', "a\n", 'CONTENT_TYPE' => 'text/markdown', 'HTTP_AUTHORIZATION' => basic('test', @token)
    assert_equal "PUT a.md\n", git('log', '-1', '--format=%B').sub(/\n+\z/, "\n")
  end

  def test_long_poll_ignores_commits_in_other_vaults
    put '/files/a.md', "a\n", 'CONTENT_TYPE' => 'text/markdown', 'HTTP_AUTHORIZATION' => basic('test', @token)
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

  # ALLOWED_VAULTS: a vault this process doesn't serve is refused on every route, DEVICE_ONLY ones too, like a wrong
  # token; the vaults it lists work as before
  def test_allowed_vaults
    ENV['ALLOWED_VAULTS'] = 'other, notes'
    routes.each do |verb, path|
      assert_unauthorized(call(verb, path, basic('test', @token), 'HTTP_X_ROCK_SYNC_VAULT' => 'test'), "#{verb} #{path}")
    end
    assert_equal 'unauthorized: vault "test" not allowed in this process', last_request.env['vault_sync.auth']
    assert_equal 0, commit_count
    assert Devices.authenticate(@token).first, 'DELETE /token refused'
    assert_equal 200, call('GET', '/manifest', basic('other', @other_token)).status
    res = call('GET', '/vaults', basic('', @other_token))
    assert_equal [200, { 'vaults' => ['other'] }], [res.status, JSON.parse(res.body)]
  ensure
    ENV['ALLOWED_VAULTS'] = ''
  end

end
