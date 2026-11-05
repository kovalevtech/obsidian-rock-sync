# frozen_string_literal: false
# (request bodies are literals; rack-test re-encodes them: chilled literals warn under minitest)

# The HTTP API as the plugin sees it (CLAUDE.md "API"): status codes, headers, bodies, what ends up in git.
# Doesn't depend on how the server is built inside — the refactor keeps it green unchanged.
require_relative 'test_helper'
require 'json'

class ApiTest < VaultTest
  include Rack::Test::Methods

  def app = App

  def setup
    super
    basic_authorize('test', @token)
  end

  BINARY = { 'CONTENT_TYPE' => 'application/octet-stream' }.freeze
  MARKDOWN = { 'CONTENT_TYPE' => 'text/markdown' }.freeze

  # Each segment URL-encoded, like the plugin's encodePath
  def url(path)
    path.split('/').map { URI.encode_uri_component(_1) }.join('/')
  end

  # Content-Type like the plugin's: text (mergeable) for notes, bytes for everything else
  def put_file(path, body, if_match: nil, if_none_match: nil)
    env = (path.end_with?('.md') ? MARKDOWN : BINARY).dup
    env['HTTP_IF_MATCH'] = if_match if if_match
    env['HTTP_IF_NONE_MATCH'] = if_none_match if if_none_match
    put "/files/#{url(path)}", body, env
    last_response
  end

  # Creates path with base, then the server moves on to server: [base hash, server hash]
  def diverge(path, base, server)
    put_file(path, base, if_none_match: '*')
    base_hash = last_response['ETag']
    put_file(path, server, if_match: base_hash)
    [base_hash, last_response['ETag']]
  end

  def manifest
    get '/manifest', 'v' => '1'
    JSON.parse(last_response.body)
  end

  # PUT

  def test_create
    res = put_file('notes/a.md', "hello\n", if_none_match: '*')
    assert_equal 204, res.status
    assert_equal blob("hello\n"), res['ETag']
    assert_equal "hello\n", File.read(tree_file('notes/a.md'))
    assert_equal 'PUT notes/a.md', last_commit_message
  end

  def test_create_over_existing_returns_server_version
    put_file('a.md', "server\n", if_none_match: '*')
    res = put_file('a.md', "mine\n", if_none_match: '*')
    assert_equal 412, res.status
    assert_equal "server\n", res.body
    assert_equal blob("server\n"), res['ETag']
    refute_nil res['Last-Modified']
  end

  def test_identical_content_succeeds_regardless_of_headers
    put_file('a.md', "same\n", if_none_match: '*')
    count = commit_count
    res = put_file('a.md', "same\n", if_match: 'f' * 40)
    assert_equal 204, res.status
    assert_equal blob("same\n"), res['ETag']
    assert_equal count, commit_count
  end

  def test_update_with_current_if_match
    put_file('a.md', "one\n", if_none_match: '*')
    res = put_file('a.md', "two\n", if_match: blob("one\n"))
    assert_equal 204, res.status
    assert_equal blob("two\n"), res['ETag']
    assert_equal "two\n", File.read(tree_file('a.md'))
  end

  def test_stale_if_match_merges_cleanly
    base_hash, = diverge('a.md', "1\n2\n3\n4\n5\n", "1 server\n2\n3\n4\n5\n")
    res = put_file('a.md', "1\n2\n3\n4\n5 mine\n", if_match: base_hash)
    merged = "1 server\n2\n3\n4\n5 mine\n"
    assert_equal 200, res.status
    assert_equal merged, res.body
    assert_equal blob(merged), res['ETag']
    assert_equal merged, File.read(tree_file('a.md'))
    assert_equal 'MERGE a.md', last_commit_message
  end

  def test_stale_if_match_with_conflicts_returns_markers_and_writes_nothing
    base_hash, server_hash = diverge('a.md', "1\n2\n3\n", "1\n2 server\n3\n")
    count = commit_count
    res = put_file('a.md', "1\n2 mine\n3\n", if_match: base_hash)
    assert_equal 409, res.status
    assert_equal server_hash, res['ETag']
    refute_nil res['Last-Modified']
    assert_match(/\A1\n<{9} server \d{4}-\d\d-\d\dT\d\d:\d\dZ\n2 server\n={9}\n2 mine\n>{9} mine\n3\n\z/, res.body)
    assert_equal "1\n2 server\n3\n", File.read(tree_file('a.md'))
    assert_equal count, commit_count
  end

  def test_unknown_base_returns_server_version
    put_file('a.md', "server\n", if_none_match: '*')
    res = put_file('a.md', "mine\n", if_match: 'f' * 40)
    assert_equal 412, res.status
    assert_equal "server\n", res.body
    assert_equal blob("server\n"), res['ETag']
  end

  # Text to git, but sent as bytes (SVG, canvas, excalidraw): never merged, markers would break it
  def test_stale_if_match_on_bytes_returns_server_version_and_writes_nothing
    base_hash, server_hash = diverge('a.svg', "<svg>\n1\n2\n3\n</svg>\n", "<svg>\n1 server\n2\n3\n</svg>\n")
    count = commit_count
    res = put_file('a.svg', "<svg>\n1\n2\n3 mine\n</svg>\n", if_match: base_hash)
    assert_equal 412, res.status
    assert_equal "<svg>\n1 server\n2\n3\n</svg>\n", res.body
    assert_equal server_hash, res['ETag']
    assert_equal count, commit_count

    post '/merge/a.svg', "<svg>\n1\n2\n3 mine\n</svg>\n", BINARY.merge('HTTP_IF_MATCH' => base_hash)
    assert_equal 412, last_response.status
    assert_equal server_hash, last_response['ETag']
  end

  def test_over_the_size_limit_is_413_and_writes_nothing
    ENV['MAX_FILE_SIZE'] = '10'
    assert_equal 413, put_file('big.bin', 'x' * 11, if_none_match: '*').status
    post '/merge/a.md', 'x' * 11, MARKDOWN.merge('HTTP_IF_MATCH' => blob("x\n"))
    assert_equal 413, last_response.status
    assert_equal 204, put_file('small.bin', 'x' * 10, if_none_match: '*').status
    refute File.exist?(tree_file('big.bin'))
  ensure
    ENV.delete('MAX_FILE_SIZE')
  end

  def test_if_match_on_a_gone_file_is_412_without_body
    put_file('other.md', "o\n", if_none_match: '*') # git log fails in a repo without commits (500): never in practice
    res = put_file('gone.md', "mine\n", if_match: blob("old\n"))
    assert_equal 412, res.status
    assert_empty res.body
    assert_nil res['ETag']
  end

  def test_mine_is_kept_in_git_even_when_conflicting
    base_hash, = diverge('a.md', "1\n2\n3\n", "1\n2 server\n3\n")
    put_file('a.md', "1\n2 mine\n3\n", if_match: base_hash)
    assert system('git', "--git-dir=#{@vaults_dir}/test/repo.git", 'cat-file', '-e', blob("1\n2 mine\n3\n"))
  end

  # POST /merge (dry run)

  def test_merge_dry_run
    base_hash, server_hash = diverge('a.md', "1\n2\n3\n4\n5\n", "1 server\n2\n3\n4\n5\n")
    count = commit_count

    post '/merge/a.md', "1\n2\n3\n4\n5 mine\n", MARKDOWN.merge('HTTP_IF_MATCH' => base_hash)
    assert_equal 200, last_response.status
    assert_equal "1 server\n2\n3\n4\n5 mine\n", last_response.body
    assert_equal server_hash, last_response['ETag']
    refute_nil last_response['Last-Modified']

    post '/merge/a.md', "1 mine\n2\n3\n4\n5\n", MARKDOWN.merge('HTTP_IF_MATCH' => base_hash)
    assert_equal 409, last_response.status
    assert_includes last_response.body, "<<<<<<<<< server"
    assert_equal server_hash, last_response['ETag']

    post '/merge/a.md', "x\n", MARKDOWN.merge('HTTP_IF_MATCH' => 'f' * 40)
    assert_equal 412, last_response.status
    assert_equal "1 server\n2\n3\n4\n5\n", last_response.body
    assert_equal server_hash, last_response['ETag']

    assert_equal count, commit_count
    assert_equal "1 server\n2\n3\n4\n5\n", File.read(tree_file('a.md'))
  end

  def test_merge_dry_run_on_a_gone_file
    post '/merge/gone.md', "x\n", MARKDOWN.merge('HTTP_IF_MATCH' => blob("x\n"))
    assert_equal 404, last_response.status
  end

  # GET

  def test_get
    put_file('a b/ё.md', "привет\n", if_none_match: '*')
    get "/files/#{url('a b/ё.md')}"
    assert_equal 200, last_response.status
    assert_equal "привет\n".b, last_response.body.b
    assert_equal blob("привет\n"), last_response['ETag']
    refute_nil last_response['Last-Modified']
  end

  def test_get_not_modified
    put_file('a.md', "x\n", if_none_match: '*')
    get '/files/a.md', {}, 'HTTP_IF_NONE_MATCH' => blob("x\n")
    assert_equal 304, last_response.status
    assert_empty last_response.body
  end

  def test_get_missing
    get '/files/missing.md'
    assert_equal 404, last_response.status
  end

  # GET /manifest

  def test_manifest
    assert_equal({ 'version' => nil, 'files' => {} }, manifest)
    put_file('a.md', "a\n", if_none_match: '*')
    put_file('d/b.md', "bb\n", if_none_match: '*')
    m = manifest
    assert_equal({ 'a.md' => [blob("a\n"), 2], 'd/b.md' => [blob("bb\n"), 3] }, m['files'])
    assert_match(/\A\h{40}\z/, m['version'])
    assert_equal %("#{m['version']}"), last_response['ETag']

    get '/manifest', {}, 'HTTP_IF_NONE_MATCH' => last_response['ETag']
    assert_equal 304, last_response.status
  end

  def test_manifest_v0_without_version_param
    put_file('a.md', "a\n", if_none_match: '*')
    get '/manifest'
    assert_equal({ 'a.md' => blob("a\n") }, JSON.parse(last_response.body)['files'])
  end

  def test_long_poll_wakes_on_commit
    put_file('a.md', "a\n", if_none_match: '*')
    etag = (get '/manifest')['ETag']
    poller = Thread.new do
      session = Rack::Test::Session.new(App)
      session.basic_authorize('test', @token)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      session.get '/manifest', { 'wait' => '10' }, 'HTTP_IF_NONE_MATCH' => etag
      [session.last_response, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end
    sleep 0.3
    put_file('b.md', "b\n", if_none_match: '*')
    res, took = poller.value
    assert_equal 200, res.status
    assert_operator took, :<, 3
    assert_includes JSON.parse(res.body)['files'], 'b.md'
  end

  def test_long_poll_times_out_with_304
    put_file('a.md', "a\n", if_none_match: '*')
    etag = (get '/manifest')['ETag']
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get '/manifest', { 'wait' => '1' }, 'HTTP_IF_NONE_MATCH' => etag
    assert_equal 304, last_response.status
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.9
  end

  def test_long_poll_without_version_answers_right_away
    put_file('a.md', "a\n", if_none_match: '*')
    get '/manifest', { 'wait' => '10' }
    assert_equal 200, last_response.status
  end

  # Before the first commit too: a poll needs something to wait past, or it's answered at once, again and again
  def test_empty_vault_has_an_etag_and_answers_304
    get '/manifest'
    etag = last_response['ETag']
    refute_nil etag
    get '/manifest', {}, 'HTTP_IF_NONE_MATCH' => etag
    assert_equal 304, last_response.status
  end

  def test_long_poll_waits_on_an_empty_vault
    etag = (get '/manifest')['ETag']
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get '/manifest', { 'wait' => '1' }, 'HTTP_IF_NONE_MATCH' => etag
    assert_equal 304, last_response.status
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.9
  end

  def test_long_poll_on_an_empty_vault_wakes_on_the_first_commit
    etag = (get '/manifest')['ETag']
    poller = Thread.new do
      session = Rack::Test::Session.new(App)
      session.basic_authorize('test', @token)
      session.get '/manifest', { 'wait' => '10' }, 'HTTP_IF_NONE_MATCH' => etag
      session.last_response
    end
    sleep 0.3
    put_file('a.md', "a\n", if_none_match: '*')
    res = poller.value
    assert_equal 200, res.status
    assert_includes JSON.parse(res.body)['files'], 'a.md'
    refute_equal etag, res['ETag']
  end

  # Without it Obsidian's requestUrl (Chromium's HTTP cache) answers from the cache, the server never asked: a file
  # with a Last-Modified counts as fresh for a tenth of its age
  def test_nothing_may_be_cached
    put_file('a.md', "a\n", if_none_match: '*')
    etag = last_response['ETag']
    [
      -> { get '/files/a.md' },
      -> { get '/files/a.md', {}, 'HTTP_IF_NONE_MATCH' => etag },
      -> { get '/files/missing.md' },
      -> { get '/manifest' },
      -> { get '/manifest', {}, 'HTTP_IF_NONE_MATCH' => last_response['ETag'] },
      -> { get '/vaults' },
    ].each do |call|
      call.call
      assert_equal 'no-store', last_response['Cache-Control'], last_request.url
    end
  end

  # DELETE

  def test_delete
    put_file('d/e/a.md', "a\n", if_none_match: '*')
    put_file('keep.md', "k\n", if_none_match: '*')
    delete '/files/d/e/a.md', {}, 'HTTP_IF_MATCH' => blob("a\n")
    assert_equal 204, last_response.status
    assert_equal 'DELETE d/e/a.md', last_commit_message
    refute manifest['files'].key?('d/e/a.md')
    refute File.exist?(tree_file('d')) # empty dirs pruned
  end

  def test_delete_already_gone
    put_file('keep.md', "k\n", if_none_match: '*')
    count = commit_count
    delete '/files/gone.md', {}, 'HTTP_IF_MATCH' => blob("x\n")
    assert_equal 204, last_response.status
    assert_equal count, commit_count
  end

  def test_delete_edited_elsewhere_returns_current_version
    put_file('a.md', "edited\n", if_none_match: '*')
    delete '/files/a.md', {}, 'HTTP_IF_MATCH' => blob("old\n")
    assert_equal 412, last_response.status
    assert_equal "edited\n", last_response.body
    assert_equal blob("edited\n"), last_response['ETag']
    refute_nil last_response['Last-Modified']
    assert File.exist?(tree_file('a.md'))
  end

  # POST /move

  def test_move
    put_file('d/a.md', "a\n", if_none_match: '*')
    post '/move/d/a.md', nil, 'HTTP_DESTINATION' => url('новая папка/b.md')
    assert_equal 204, last_response.status
    assert_equal blob("a\n"), last_response['ETag']
    assert_equal({ 'новая папка/b.md' => [blob("a\n"), 2] }, manifest['files'])
    assert_equal 'RENAME d/a.md → новая папка/b.md', last_commit_message.force_encoding('UTF-8')
    refute File.exist?(tree_file('d'))
  end

  def test_move_onto_existing
    put_file('a.md', "a\n", if_none_match: '*')
    put_file('b.md', "b\n", if_none_match: '*')
    post '/move/a.md', nil, 'HTTP_DESTINATION' => 'b.md'
    assert_equal 409, last_response.status
    assert_equal "b\n", File.read(tree_file('b.md'))
  end

  def test_move_missing_source
    post '/move/gone.md', nil, 'HTTP_DESTINATION' => 'b.md'
    assert_equal 404, last_response.status
  end

  def test_move_without_destination
    post '/move/a.md'
    assert_equal 400, last_response.status
  end
end
