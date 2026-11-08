# frozen_string_literal: false
# The MCP endpoint over HTTP, mounted as config.ru does (/mcp next to App): JSON-RPC bodies in, what Claude sees out,
# what ends up in git. Scoped token `claude` (Bearer) with grants in vault `test`: Inbox (w), Journal (rw), Archive (r),
# Notes (r) + Notes/Drafts (w).
require_relative 'test_helper'
require_relative '../mcp_endpoint'
require 'json'
require 'stringio'

class McpTest < VaultTest
  include Rack::Test::Methods

  GRANTS = { 'Archive' => 'r', 'Inbox' => 'w', 'Journal' => 'rw', 'Notes' => 'r', 'Notes/Drafts' => 'w' }.freeze

  def app
    Rack::Builder.new do
      map('/mcp') { run McpEndpoint }
      run App
    end
  end

  def setup
    super
    McpTools::RATE.reset
    %w[Inbox Journal Archive Notes Notes/Drafts Inbox2].each { commit_file("#{_1}/.keep", '') }
    @claude, @secret = Devices.create_scoped(name: 'claude', grants: rows(GRANTS))
  end

  def rows(grants, vault = 'test') = grants.map { |folder, mode| { vault:, folder:, mode: } }

  def rpc(method, params = nil, id: 1, secret: @secret, path: '/mcp')
    body = { jsonrpc: '2.0', method: }
    body[:id] = id if id
    body[:params] = params if params
    post path, JSON.generate(body), 'CONTENT_TYPE' => 'application/json',
                                    'HTTP_ACCEPT' => 'application/json, text/event-stream',
                                    'HTTP_AUTHORIZATION' => "Bearer #{secret}"
    last_response
  end

  # tools/call → [result JSON (or the error's text), isError]
  def tool(name, secret: @secret, **arguments)
    res = rpc('tools/call', { name:, arguments: }, secret:)
    assert_equal 200, res.status, res.body
    result = JSON.parse(res.body).fetch('result')
    text = result.dig('content', 0, 'text')
    error = result['isError'] == true
    [error ? text : JSON.parse(text), error]
  end

  def ok(name, **arguments)
    result, error = tool(name, **arguments)
    refute error, result
    result
  end

  def refused(name, **arguments)
    result, error = tool(name, **arguments)
    assert error, "#{name} #{arguments}: #{result}"
    result
  end

  def grants_of(token_id) = Grants.of(token_id).to_h { [_1.folder, _1.mode] }

  # Auth

  def test_bearer_header
    res = rpc('tools/list')
    assert_equal 200, res.status
    assert_equal 'mcp token=claude', last_request.env['vault_sync.auth']
    assert_equal 200, rpc('tools/list', path: '/mcp/').status
    header 'Authorization', "bearer #{@secret}" # the scheme is case-insensitive
    post '/mcp', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}', 'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status
  end

  def test_no_good_token_is_401
    revoked, revoked_secret = Devices.create_scoped(name: 'old', grants: rows('Inbox' => 'w'))
    Devices.revoke(revoked.id)
    {
      'no header' => nil, 'Basic' => "Basic #{["test:#{@secret}"].pack('m0')}", 'no token' => 'Bearer ',
      'bare token' => @secret, 'unknown' => "Bearer #{'x' * 43}", 'revoked' => "Bearer #{revoked_secret}",
      "a device's token" => "Bearer #{@token}", 'two tokens' => "Bearer #{@secret} #{@secret}"
    }.each do |why, authorization|
      %w[POST GET DELETE].each do |verb|
        env = authorization ? { 'HTTP_AUTHORIZATION' => authorization } : {}
        custom_request(verb, '/mcp', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}', env)
        assert_equal 401, last_response.status, "#{verb} #{why}"
        assert_equal 'Bearer', last_response['WWW-Authenticate'], "#{verb} #{why}"
        assert_equal({ 'error' => 'unauthorized' }, JSON.parse(last_response.body))
        assert_equal 'mcp auth failed', last_request.env['vault_sync.auth'], "#{verb} #{why}"
      end
    end
  end

  # The token in the path was the old way: gone, not even with a good header
  def test_paths_below_mcp_are_unknown
    basic_authorize('test', @token)
    get '/nope'
    unknown = [last_response.status, last_response.body]
    assert_equal [404, ''], unknown
    header 'Authorization', nil

    ["/mcp/#{@secret}", '/mcp/x', "/mcp/#{@secret}/x"].each do |path|
      [nil, "Bearer #{@secret}"].each do |authorization|
        env = authorization ? { 'HTTP_AUTHORIZATION' => authorization } : {}
        custom_request('POST', path, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}', env)
        assert_equal unknown, [last_response.status, last_response.body], "#{path} #{authorization}"
      end
    end
  end

  def test_get_and_delete_are_405
    %w[GET DELETE PUT].each do |verb|
      custom_request(verb, '/mcp', nil, 'HTTP_AUTHORIZATION' => "Bearer #{@secret}")
      assert_equal 405, last_response.status, verb
      assert_equal 'POST', last_response['Allow'], verb
    end
  end

  # Never parsed (FormBody): over Rack's params limit, parsed, it was a 500 before the token was looked at
  def test_form_bodies_are_refused_unparsed
    { 'application/x-www-form-urlencoded' => 'a=1&' * 5000,
      'multipart/form-data; boundary=x' => "--x\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nf\r\n--x--\r\n" }
      .each do |type, body|
        { nil => 401, "Bearer #{@secret}x" => 401, "Bearer #{@secret}" => 415 }.each do |header, status|
          env = { 'CONTENT_TYPE' => type, input: body }
          env['HTTP_AUTHORIZATION'] = header if header
          post '/mcp', nil, env
          assert_equal status, last_response.status, "#{type}, #{header.inspect}"
          assert_equal [[], nil], [last_request.env['rack.request.form_pairs'], last_request.env['rack.request.form_vars']]
        end
      end
  end

  def test_the_sync_api_refuses_a_scoped_token
    basic_authorize('test', @secret)
    get '/manifest'
    assert_equal 401, last_response.status
    assert_equal 'unauthorized: scoped token', last_request.env['vault_sync.auth']
    get '/vaults'
    assert_equal 401, last_response.status
  end

  def test_requests_mark_the_token_seen
    rpc('tools/list')
    assert_in_delta Time.now, DB[:devices].where(id: @claude.id).get(:last_seen_at), 5
  end

  # Protocol

  def test_initialize_tells_the_grants
    res = rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'claude-ai', version: '1' } })
    assert_equal 200, res.status
    assert_match %r{\Aapplication/json}, res.content_type
    result = JSON.parse(res.body)['result']
    assert_equal '2025-06-18', result['protocolVersion']
    assert_equal({ 'tools' => {} }, result['capabilities'])
    instructions = result['instructions']
    GRANTS.each { |folder, mode| assert_includes instructions, "- test: `#{folder}` (#{mode})" }
    assert_includes instructions, 'list_access'
    assert_includes instructions, 'it can be left out'

    assert_equal 202, rpc('notifications/initialized', id: nil).status
    assert_equal '', last_response.body
  end

  def test_tools_list
    tools = JSON.parse(rpc('tools/list').body).dig('result', 'tools')
    assert_equal %w[append_file delete_file list_access list_folder read_file write_file], tools.map { _1['name'] }.sort
    tools.each { assert_includes _1.dig('inputSchema', 'properties').keys, 'vault', _1['name'] unless _1['name'] == 'list_access' }
  end

  def test_list_access
    expected = GRANTS.map { |folder, mode| { 'vault' => 'test', 'folder' => folder, 'mode' => mode } }
    assert_equal expected, ok('list_access')
  end

  # A grant's purpose: in list_access (when there is one) and after its grant in the instructions
  def test_purposes
    Grants.save(@claude.id, [{ vault: 'test', folder: '', mode: 'r', purpose: '' },
                             { vault: 'test', folder: 'Claude', mode: 'w', purpose: "Your memory mirror.\nOne note per memory." }])
    assert_equal [{ 'vault' => 'test', 'folder' => '/', 'mode' => 'r' },
                  { 'vault' => 'test', 'folder' => 'Claude', 'mode' => 'w', 'purpose' => "Your memory mirror.\nOne note per memory." }],
                 ok('list_access')
    instructions = JSON.parse(rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {},
                                                  clientInfo: { name: 'c', version: '1' } }).body).dig('result', 'instructions')
    assert_includes instructions, "- test: `/` (r)\n- test: `Claude` (w) — Your memory mirror.\n  One note per memory.\n"
  end

  def test_no_grants_nothing_to_do
    _, secret = Devices.create_scoped(name: 'empty')
    assert_equal [[], false], tool('list_access', secret:)
    assert_includes rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'c', version: '1' } },
                        secret:).body, 'none: nothing can be read or written yet'
    message, = tool('write_file', secret:, path: 'Inbox/a.md', content: 'a')
    assert_equal 'Nothing is granted to you: nothing can be read or written.', message
    message, = tool('read_file', secret:, path: 'Inbox/a.md')
    assert_equal 'Nothing is granted to you: nothing can be read or written.', message
  end

  # Grants: the union of the modes of every grant holding a path, by segment. Whatever a token may not do with a path
  # reads like a path that isn't there

  def test_reads_writes_and_deletes_by_the_union_of_modes
    {
      'Inbox/a.md' => 'w', 'Inbox/sub/deep/b.md' => 'w', 'Journal/x.md' => 'rw', 'Archive/x.md' => 'r',
      'Notes/x.md' => 'r', 'Notes/Drafts/x.md' => 'rw', # r from Notes + w from Notes/Drafts
      'Inbox2/x.md' => '', 'Inboxx.md' => '', 'x.md' => ''
    }.each do |path, mode|
      etag = commit_file(path, "#{path}\n")
      result, error = tool('read_file', path:)
      assert_equal !mode.include?('r'), error, "read #{path}: #{result}"
      assert_equal "`#{path}` not found in test.", result if error
      result, error = tool('write_file', path:, content: "new #{path}\n", base: etag)
      assert_equal !mode.include?('w'), error, "write #{path}: #{result}"
      assert_equal "`#{path}` not found in test.", result if error
      etag = Git.blob_hash(File.read(tree_file(path)))
      result, error = tool('delete_file', path:, base: etag)
      assert_equal mode != 'rw', error, "delete #{path}: #{result}"
      assert_equal "`#{path}` not found in test.", result if error
    end
    assert File.exist?(tree_file('Inbox2/x.md'))
    assert_equal 'written', ok('write_file', path: '/Inbox/lead.md', content: "l\n")['status'], 'a leading / is fine'
    assert_equal '`Archive/gone.md` not found in test.', refused('read_file', path: 'Archive/gone.md'), 'missing = not granted'
  end

  def test_a_whole_vault_grant
    Grants.save(@claude.id, rows('' => 'w'))
    assert_equal [{ 'vault' => 'test', 'folder' => '/', 'mode' => 'w' }], ok('list_access')
    assert_equal 'written', ok('write_file', path: 'x.md', content: "x\n")['status']
  end

  def test_hidden_and_escaping_paths
    Grants.save(@claude.id, rows('' => 'rw'))
    keep = commit_file('.obsidian/app.json', '{}')
    before = commit_count
    ['.plugins/x/data.json', '.obsidian/app.json', 'Inbox/.keep', '.keep', 'Inbox/.hidden/a.md', '../x.md',
     'Inbox/../../x.md', ''].each do |path|
      refused('write_file', path:, content: 'x')
      refused('append_file', path:, text: 'x')
      refused('read_file', path:)
      refused('delete_file', path:, base: keep)
    end
    assert_equal before, commit_count
    assert_includes refused('write_file', path: '../x.md', content: 'x'), "isn't a path inside the vault"
    assert_equal '`.obsidian` not found in test.', refused('list_folder', path: '.obsidian')
    commit_file('Inbox/n.md', "n\n")
    assert_equal %w[Inbox/n.md], ok('list_folder').map { _1['path'] }, '.keep files and .obsidian left out'
  end

  # Vaults: named when the grants are in several, optional with one

  def test_vaults
    Vault.create('work')
    assert_equal 'Vault `work` not found.', refused('write_file', path: 'Inbox/a.md', content: 'a', vault: 'work')
    assert_equal 'written', ok('write_file', path: 'Inbox/a.md', content: "a\n", vault: 'test')['status']

    Grants.save(@claude.id, rows(GRANTS) + rows({ 'Inbox' => 'rw' }, 'work'))
    assert_equal 'Name the vault (`vault`): one of `test`, `work`.', refused('write_file', path: 'Inbox/b.md', content: 'b')
    assert_equal 'Name the vault (`vault`): one of `test`, `work`.', refused('list_folder')
    assert_equal 'Vault `nope` not found.', refused('read_file', path: 'Inbox/a.md', vault: 'nope')

    written = ok('write_file', path: 'Inbox/b.md', content: "b\n", vault: 'work')
    assert_equal "b\n", File.read(tree_file('Inbox/b.md', vault: 'work'))
    refute File.exist?(tree_file('Inbox/b.md'))
    assert_equal written['etag'], ok('read_file', path: 'Inbox/b.md', vault: 'work')['etag']
    assert_equal %w[Inbox/b.md], ok('list_folder', vault: 'work').map { _1['path'] }
    assert_equal '`Inbox/a.md` not found in test.', refused('read_file', path: 'Inbox/a.md', vault: 'test'), 'w in test, rw in work'
    assert_equal({ 'vault' => 'work', 'folder' => 'Inbox', 'mode' => 'rw' }, ok('list_access').last)
    assert_includes rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'c', version: '1' } }).body,
                    'name one in every tool call'
  end

  # read_file / list_folder

  def test_read_file
    etag = commit_file('Journal/today.md', "Привет\n")
    result = ok('read_file', path: 'Journal/today')
    assert_equal({ 'path' => 'Journal/today.md', 'etag' => etag, 'content' => "Привет\n",
                   'author' => { 'kind' => 'unknown', 'name' => 'sync' } }, result.except('modified_at'))
    assert_equal Time.at(git('log', '-1', '--format=%ct').to_i).utc.iso8601, result['modified_at']
    assert_equal "`Journal/gone.md` not found in test.", refused('read_file', path: 'Journal/gone.md')
    commit_file('Journal/x.d/a.md', "a\n")
    assert_equal '`Journal/x.d` is a folder: name a file inside it.', refused('read_file', path: 'Journal/x.d/')
  end

  def test_read_file_refuses_binary_and_big_files
    png = commit_file('Journal/a.png', "\x89PNG\xff\xfe".b) # not a PNG's whole signature
    assert_equal "`Journal/a.png` is binary (6 bytes, etag #{png}): only text files and images (PNG, JPEG, GIF, WebP) can be read.",
                 refused('read_file', path: 'Journal/a.png')
    commit_file('Journal/nul.txt', "a\0b")
    assert_includes refused('read_file', path: 'Journal/nul.txt'), 'is binary (3 bytes'
    big = commit_file('Journal/big.md', 'x' * (McpTools::READ_MAX + 1))
    assert_equal "`Journal/big.md` is #{McpTools::READ_MAX + 1} bytes (etag #{big}), at most #{McpTools::READ_MAX} can be read.",
                 refused('read_file', path: 'Journal/big.md')
  end

  PNG = "\x89PNG\r\n\x1A\n\0\0\0\rIHDR\xff".b
  IMAGES = {
    'a.png' => [PNG, 'image/png'], 'b.jpg' => ["\xFF\xD8\xFF\xE0\0\x10JFIF".b, 'image/jpeg'],
    'c.gif' => ['GIF89a..'.b, 'image/gif'], 'd.md' => ['GIF87a..'.b, 'image/gif'],
    'e.webp' => ["RIFF\x10\0\0\0WEBPVP8 ".b, 'image/webp']
  }.freeze

  # Images: their JSON (no content), then the image itself, over READ_MAX too; known by their bytes, not the name
  def test_read_file_shows_images
    IMAGES.each do |name, (bytes, mime_type)|
      path = "Journal/#{name}"
      etag = commit_file(path, bytes)
      result = JSON.parse(rpc('tools/call', { name: 'read_file', arguments: { path: } }).body)['result']
      refute result['isError'], result
      info, image = result['content']
      assert_equal 'text', info['type']
      assert_equal({ 'path' => path, 'etag' => etag, 'size' => bytes.bytesize, 'mime_type' => mime_type,
                     'author' => { 'kind' => 'unknown', 'name' => 'sync' } }, JSON.parse(info['text']).except('modified_at'))
      assert_equal({ 'type' => 'image', 'mimeType' => mime_type }, image.except('data'))
      assert_equal bytes, image['data'].unpack1('m0')
    end

    commit_file('Journal/mid.png', PNG + ("\0" * McpTools::READ_MAX))
    assert_equal McpTools::READ_MAX + PNG.bytesize, ok('read_file', path: 'Journal/mid.png')['size']
    big = commit_file('Journal/big.png', PNG + ("\0" * McpTools::IMAGE_MAX))
    assert_equal "`Journal/big.png` is an image of #{McpTools::IMAGE_MAX + PNG.bytesize} bytes (etag #{big}), at most #{McpTools::IMAGE_MAX} can be read.",
                 refused('read_file', path: 'Journal/big.png')
  end

  def test_list_folder_shows_only_what_is_readable
    files = { 'Journal/a.md' => 'a', 'Journal/sub/b.md' => 'bb', 'Archive/old.md' => 'o', 'Notes/n.md' => 'n',
              'Notes/Drafts/d.md' => 'd', 'Inbox/i.md' => 'i', 'x.md' => 'x', 'Journal/.hidden/h.md' => 'h' }
    files.each { commit_file(_1, _2) }

    listed = ok('list_folder')
    assert_equal %w[Archive/old.md Journal/a.md Journal/sub/b.md Notes/Drafts/d.md Notes/n.md], listed.map { _1['path'] }
    assert_equal({ 'path' => 'Journal/sub/b.md', 'etag' => blob('bb'), 'size' => 2, 'author' => { 'kind' => 'unknown', 'name' => 'sync' } },
                 listed[2].except('modified_at'))
    assert_equal %w[Journal/a.md Journal/sub/b.md], ok('list_folder', path: 'Journal').map { _1['path'] }
    assert_equal %w[Journal/a.md], ok('list_folder', path: 'Journal', recursive: false).map { _1['path'] }
    assert_equal [], ok('list_folder', recursive: false), 'x.md at the root is no one\'s'
    assert_equal %w[Journal/sub/b.md], ok('list_folder', path: '/Journal/sub/').map { _1['path'] }
    assert_equal '`Journal/none` not found in test.', refused('list_folder', path: 'Journal/none')
    assert_equal '`Inbox` not found in test.', refused('list_folder', path: 'Inbox'), 'w only'
    assert_equal '`Inbox2` not found in test.', refused('list_folder', path: 'Inbox2'), 'no grant'
    assert_includes refused('list_folder', path: '../x'), "isn't a path inside the vault"

    # A folder holding a readable one: only what's readable inside it
    Grants.save(@claude.id, rows('Notes/Drafts' => 'r', 'Inbox' => 'w'))
    assert_equal %w[Notes/Drafts/d.md], ok('list_folder', path: 'Notes').map { _1['path'] }
    assert_equal %w[Notes/Drafts/d.md], ok('list_folder').map { _1['path'] }

    Grants.save(@claude.id, rows('Inbox' => 'w'))
    assert_equal '`/` not found in test.', refused('list_folder')
  end

  # One walk back through history for every file listed, whatever their number; the last commit per file wins
  def test_list_folder_takes_each_files_last_commit
    50.times { commit_file("Journal/#{_1}.md", "#{_1}\n") }
    ok('write_file', path: 'Journal/7.md', content: "seven\n", base: blob("7\n"))
    listed = ok('list_folder', path: 'Journal').to_h { [_1['path'], _1['author']] }
    assert_equal 50, listed.size
    assert_equal({ 'kind' => 'token', 'name' => 'claude' }, listed['Journal/7.md'])
    assert_equal({ 'kind' => 'unknown', 'name' => 'sync' }, listed['Journal/8.md'])
  end

  # write_file

  def test_write_file_creates
    result = ok('write_file', path: 'Inbox/Idea', content: "idea\n")
    assert_equal({ 'status' => 'written', 'path' => 'Inbox/Idea.md', 'etag' => blob("idea\n") }, result)
    assert_equal "idea\n", File.read(tree_file('Inbox/Idea.md'))
    assert_equal 'PUT Inbox/Idea.md', last_commit_message

    assert_equal 'Inbox/data.json', ok('write_file', path: 'Inbox/data.json', content: '{}')['path']
  end

  # Subfolders made by a write get their .keep (a folder on the server, like the plugin's), in the write's commit
  def test_new_subfolders_get_their_keep
    ok('write_file', path: 'Inbox/sub/deep/b.md', content: "b\n")
    assert_equal %w[Inbox/sub/.keep Inbox/sub/deep/.keep Inbox/sub/deep/b.md],
                 git('show', '--name-only', '--format=').split("\n").sort
    ok('append_file', path: 'Journal/2026/10/24.md', text: 'today')
    assert_equal %w[Journal/2026/.keep Journal/2026/10/.keep Journal/2026/10/24.md],
                 git('show', '--name-only', '--format=').split("\n").sort
    before = commit_count
    assert_equal 'exists', ok('write_file', path: 'Inbox/sub/deep/b.md', content: "other\n")['status']
    assert_equal before, commit_count
    assert_equal '', git('status', '--porcelain', "--work-tree=#{@vault.tree}"), 'nothing left staged'
  end

  def test_write_file_without_base_never_overwrites
    commit_file('Inbox/a.md', "server secret\n")
    assert_equal({ 'status' => 'exists', 'path' => 'Inbox/a.md' }, ok('write_file', path: 'Inbox/a.md', content: "mine\n"))
    refute_includes last_response.body, 'server secret'
    assert_equal "server secret\n", File.read(tree_file('Inbox/a.md'))
    assert_equal 'unchanged', ok('write_file', path: 'Inbox/a.md', content: "server secret\n")['status']
  end

  # With base: written only over that very version, never merged
  def test_write_file_with_base
    base = ok('write_file', path: 'Journal/a.md', content: "one\ntwo\nthree\n")['etag']
    replaced = ok('write_file', path: 'Journal/a.md', content: "one\n2\nthree\n", base:)
    assert_equal({ 'status' => 'written', 'path' => 'Journal/a.md', 'etag' => blob("one\n2\nthree\n") }, replaced)
    assert_equal 'unchanged', ok('write_file', path: 'Journal/a.md', content: "one\n2\nthree\n", base:)['status']

    # Another device changes the last line: stale (not merged), with the current etag — Journal is readable
    phone = commit_file('Journal/a.md', "one\n2\nthree, from the phone\n")
    before = commit_count
    assert_equal({ 'status' => 'stale', 'path' => 'Journal/a.md', 'etag' => phone },
                 ok('write_file', path: 'Journal/a.md', content: "uno\n2\nthree\n", base: replaced['etag']))
    refute_includes last_response.body, 'phone'
    assert_equal before, commit_count
    assert_equal 'written', ok('write_file', path: 'Journal/a.md', content: "uno\n2\nthree, from the phone\n", base: phone)['status']
  end

  # Where Claude may only write, a stale answer carries no etag: no blind overwrite of a version it can't read
  def test_write_file_stale_where_unreadable
    base = ok('write_file', path: 'Inbox/a.canvas', content: '{"nodes":[]}')['etag']
    commit_file('Inbox/a.canvas', '{"nodes":[1]}')
    assert_equal({ 'status' => 'stale', 'path' => 'Inbox/a.canvas' },
                 ok('write_file', path: 'Inbox/a.canvas', content: '{"nodes":[2]}', base:))
    refute_includes last_response.body, 'nodes'
    assert_equal({ 'status' => 'stale', 'path' => 'Inbox/b.md' }, ok('write_file', path: 'Inbox/b.md', content: 'b', base:))
    refute File.exist?(tree_file('Inbox/b.md'))
    assert_includes refused('write_file', path: 'Inbox/a.md', content: 'a', base: 'nope'), 'base'
  end

  # delete_file

  def test_delete_file
    etag = commit_file('Journal/sub/old.md', "old\n")
    commit_file('Journal/sub/.keep', '')
    assert_equal({ 'status' => 'deleted', 'path' => 'Journal/sub/old.md' }, ok('delete_file', path: 'Journal/sub/old', base: etag))
    refute File.exist?(tree_file('Journal/sub/old.md'))
    assert_equal 'DELETE Journal/sub/old.md', last_commit_message
    assert_equal "claude <claude@token>\n", git('log', '-1', '--format=%an <%ae>').sub(/\n+\z/, "\n")
    assert File.exist?(tree_file('Journal/sub/.keep')), 'the folder stays'

    before = commit_count
    assert_equal({ 'status' => 'gone', 'path' => 'Journal/sub/old.md' }, ok('delete_file', path: 'Journal/sub/old.md', base: etag))
    assert_equal before, commit_count

    edited = commit_file('Journal/b.md', "edited on the phone\n")
    assert_equal({ 'status' => 'stale', 'path' => 'Journal/b.md', 'etag' => edited },
                 ok('delete_file', path: 'Journal/b.md', base: blob("before\n")))
    assert File.exist?(tree_file('Journal/b.md'))
    assert_includes refused('delete_file', path: 'Journal/b.md', base: 'nope'), 'base'
  end

  # Empty folders go with their last file (no .keep: written by git, not by the plugin)
  def test_delete_file_prunes_empty_folders
    etag = commit_file('Journal/x/y/z.md', "z\n")
    ok('delete_file', path: 'Journal/x/y/z.md', base: etag)
    refute Dir.exist?(tree_file('Journal/x'))
    assert Dir.exist?(tree_file('Journal'))
  end

  # append_file

  def test_append_file
    assert_equal({ 'status' => 'created', 'path' => 'Inbox/log.md', 'etag' => blob('first') },
                 ok('append_file', path: 'Inbox/log', text: 'first'))
    assert_equal 'APPEND Inbox/log.md', last_commit_message
    assert_equal 'appended', ok('append_file', path: 'Inbox/log.md', text: "second\n")['status']
    assert_equal 'appended', ok('append_file', path: 'Inbox/log.md', text: 'третий')['status']
    assert_equal "first\nsecond\nтретий", File.read(tree_file('Inbox/log.md'))
    assert_equal 'APPEND Inbox/log.md', last_commit_message

    commit_file('Inbox/empty.md', '')
    ok('append_file', path: 'Inbox/empty.md', text: 'x')
    assert_equal 'x', File.read(tree_file('Inbox/empty.md'))
    assert_equal 'unchanged', ok('append_file', path: 'Inbox/empty.md', text: '')['status']
    assert_equal 'x', File.read(tree_file('Inbox/empty.md'))
    refute_includes last_response.body, 'second'
  end

  def test_append_refuses_a_binary_file
    commit_file('Inbox/a.png', "\x89PNG\xff\xfe".b)
    before = commit_count
    assert_equal "`Inbox/a.png` isn't a text file: nothing appended.", refused('append_file', path: 'Inbox/a.png', text: 'x')
    assert_equal before, commit_count
  end

  # Limits

  def test_size_cap
    ENV['MCP_MAX_WRITE'] = '10'
    before = commit_count
    assert_includes refused('write_file', path: 'Inbox/a.md', content: 'x' * 11), '`content` is 11 bytes, at most 10'
    assert_includes refused('append_file', path: 'Inbox/a.md', text: 'ё' * 6), '`text` is 12 bytes'
    assert_includes refused('write_file', path: 'Archive/a.md', content: 'x' * 11), 'bytes', 'checked before the path'
    assert_equal before, commit_count
    assert_equal 'written', ok('write_file', path: 'Inbox/a.md', content: 'x' * 10)['status']
  ensure
    ENV.delete('MCP_MAX_WRITE')
  end

  # encoding: base64 — the bytes as they are, line breaks in the base64 tolerated; the same rules as for text
  def test_write_file_base64
    bytes = PNG + "\x80\xfe\0".b
    data = [bytes].pack('m0')
    result = ok('write_file', path: 'Journal/pic.png', content: data.scan(/.{1,8}/).join("\n"), encoding: 'base64')
    assert_equal({ 'status' => 'written', 'path' => 'Journal/pic.png', 'etag' => blob(bytes) }, result)
    assert_equal bytes, File.binread(tree_file('Journal/pic.png'))
    assert_equal bytes, git('cat-file', 'blob', "HEAD:Journal/pic.png").b
    assert_equal 'unchanged', ok('write_file', path: 'Journal/pic.png', content: data, encoding: 'base64', base: blob(bytes))['status']
    assert_equal 'exists', ok('write_file', path: 'Journal/pic.png', content: 'AAEC', encoding: 'base64')['status']
    assert_equal 'written', ok('write_file', path: 'Journal/pic.png', content: 'AAEC', encoding: 'base64', base: blob(bytes))['status']
    assert_equal "\0\1\2".b, File.binread(tree_file('Journal/pic.png'))
    assert_equal 'text', ok('write_file', path: 'Journal/t.txt', content: 'text', encoding: 'text').then { File.read(tree_file(_1['path'])) }

    before = commit_count
    ["data:image/png;base64,#{data}", 'AAE', 'AA=A', 'AA*A'].each do |bad|
      assert_equal "`content` isn't valid base64 (`encoding: base64`): nothing written.",
                   refused('write_file', path: 'Journal/bad.png', content: bad, encoding: 'base64')
    end
    assert_equal before, commit_count
    refute File.exist?(tree_file('Journal/bad.png'))
  end

  def test_size_cap_base64
    ENV['MCP_MAX_WRITE'] = '10'
    before = commit_count
    [11, 12, 13].each do |size|
      assert_equal "`content` is #{size} bytes, at most 10 per call: too big to write here.",
                   refused('write_file', path: 'Archive/a.bin', content: ['x' * size].pack('m0'), encoding: 'base64')
    end
    assert_equal before, commit_count
    [8, 9, 10].each { assert_equal 'written', ok('write_file', path: "Inbox/#{_1}.bin", content: ['x' * _1].pack('m0'), encoding: 'base64')['status'] }
  ensure
    ENV.delete('MCP_MAX_WRITE')
  end

  def test_rate_limit_per_token
    _, other = Devices.create_scoped(name: 'other')
    60.times { ok('list_access') }
    assert_includes refused('list_access'), 'Too many calls'
    assert_includes refused('write_file', path: 'Inbox/a.md', content: 'a'), 'Too many calls'
    refute File.exist?(tree_file('Inbox/a.md'))
    assert_equal [[], false], tool('list_access', secret: other)
  end

  # Grants follow folder renames

  def move(from, to)
    basic_authorize('test', @token)
    post "/move/#{from}", '', 'HTTP_DESTINATION' => to
    assert_equal 204, last_response.status, "#{from} → #{to}"
    header 'Authorization', nil
  end

  def test_grants_follow_a_folder_move
    %w[Projects/A Projects/A/Sub Projects/AB].each { commit_file("#{_1}/.keep", '') }
    commit_file('Projects/A/x.md', "x\n")
    other, = Devices.create_scoped(name: 'other', grants: rows('Projects/A' => 'r'))
    Grants.save(@claude.id, rows(GRANTS.merge('Projects/A' => 'w', 'Projects/A/Sub' => 'rw', 'Projects/AB' => 'w',
                                              'Done/A' => 'r'))) # dangling: Done/A doesn't exist

    move('Projects/A/x.md', 'Projects/A/y.md') # a file, not a folder
    assert_equal 'w', grants_of(@claude.id)['Projects/A']

    # The plugin renames a folder as one move per .keep and per file: the first .keep takes the grants below it along
    move('Projects/A/.keep', 'Done/A/.keep')
    assert_equal GRANTS.merge('Done/A' => 'w', 'Done/A/Sub' => 'rw', 'Projects/AB' => 'w'), grants_of(@claude.id)
    move('Projects/A/Sub/.keep', 'Done/A/Sub/.keep')
    move('Projects/A/y.md', 'Done/A/y.md')

    assert_equal GRANTS.merge('Done/A' => 'w', 'Done/A/Sub' => 'rw', 'Projects/AB' => 'w'), grants_of(@claude.id)
    assert_equal({ 'Done/A' => 'r' }, grants_of(other.id))
    assert_equal 'written', ok('write_file', path: 'Done/A/new.md', content: "n\n")['status']
  end

  # The nested folder's .keep first (another client's order): each grant still lands where its folder went
  def test_grants_follow_nested_moves_in_any_order
    %w[P P/Sub].each { commit_file("#{_1}/.keep", '') }
    Grants.save(@claude.id, rows('P' => 'r', 'P/Sub' => 'w'))
    move('P/Sub/.keep', 'Q/Sub/.keep')
    move('P/.keep', 'Q/.keep')
    assert_equal({ 'Q' => 'r', 'Q/Sub' => 'w' }, grants_of(@claude.id))
  end

  def test_a_failing_grant_update_keeps_the_move
    commit_file('Projects/.keep', '')
    Grants.save(@claude.id, rows('Projects' => 'w'))
    DB.current.rename_table(Grants::TABLE, :grants_gone)
    _, err = capture_io { move('Projects/.keep', 'Done/.keep') }
    assert_match(/grants on Projects not moved to Done/, err)
    assert File.file?(tree_file('Done/.keep'))
    assert_equal 'RENAME Projects/.keep → Done/.keep', last_commit_message
  end

  # Commits, long polls

  def test_commits_carry_the_tokens_name
    ok('write_file', path: 'Inbox/a.md', content: "a\n")
    assert_equal "claude <claude@token>\nPUT Inbox/a.md\n\nClient: mcp\n",
                 git('log', '-1', '--format=%an <%ae>%n%B').sub(/\n+\z/, "\n")

    Devices.rename(@claude.id, 'claude-ai')
    ok('append_file', path: 'Inbox/a.md', text: 'b')
    assert_equal 'claude-ai', git('log', '-1', '--format=%an').chomp
  end

  # A file's author as the tools show it: a device (sync API), a token (MCP), from before the kinds (`@vault-sync`, told
  # apart by the trailer), the server's own
  def test_authors
    basic_authorize('test', @token)
    put '/files/Journal/phone.md', "from the phone\n", 'CONTENT_TYPE' => 'text/markdown', 'HTTP_IF_NONE_MATCH' => '*',
                                                         'HTTP_X_ROCK_SYNC_CLIENT' => 'plugin=1.0.0; platform=android'
    assert_equal 204, last_response.status
    header 'Authorization', nil
    assert_equal 'test-device <test-device@device>', git('log', '-1', '--format=%an <%ae>').chomp
    ok('write_file', path: 'Journal/claude.md', content: "from claude\n")
    { 'Journal/old-device.md' => ['pixel', 'pixel@vault-sync', 'plugin=0.1.0'], 'Journal/old-mcp.md' => ['claude-old', 'claude-old@vault-sync', 'mcp'],
      'Journal/old-bare.md' => ['laptop', 'laptop@vault-sync', nil] }.each do |path, (name, email, client)|
      File.write(tree_file(path), "#{path}\n")
      @vault.git.commit("PUT #{path}#{"\n\nClient: #{client}" if client}", { path => @vault.git.hash_object("#{path}\n") },
                        author: [name, email])
    end
    commit_file('Journal/server.md', "s\n")

    authors = ok('list_folder', path: 'Journal').to_h { [_1['path'].delete_prefix('Journal/'), _1['author'].values] }
    assert_equal({ 'phone.md' => %w[device test-device], 'claude.md' => %w[token claude], 'old-device.md' => %w[device pixel],
                   'old-mcp.md' => %w[token claude-old], 'old-bare.md' => %w[device laptop], 'server.md' => %w[unknown sync] },
                 authors)
    assert_equal({ 'kind' => 'device', 'name' => 'test-device' }, ok('read_file', path: 'Journal/phone.md')['author'])
  end

  def test_a_write_answers_the_long_poll
    basic_authorize('test', @token)
    etag = (get '/manifest')['ETag']
    header 'Authorization', nil
    poller = Thread.new do
      session = Rack::Test::Session.new(app)
      session.basic_authorize('test', @token)
      session.get '/manifest', { 'wait' => '10', 'v' => '1' }, 'HTTP_IF_NONE_MATCH' => etag
      session.last_response
    end
    sleep 0.3
    ok('write_file', path: 'Inbox/a.md', content: "a\n")
    res = poller.value
    assert_equal 200, res.status
    assert_equal [blob("a\n"), 2], JSON.parse(res.body)['files']['Inbox/a.md']
  end

  # Logs

  # config.ru as rackup runs it in development (CommonLogger around it): neither the token nor what read_file returns
  # appears in a log line
  def test_the_token_and_contents_stay_out_of_the_logs
    commit_file('Journal/secret.md', "diary entry\n")
    errors = StringIO.new
    logged = Rack::Lint.new(Rack::CommonLogger.new(config_ru, errors))
    read = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'read_file', arguments: { path: 'Journal/secret.md' } } }
    out, = capture_io do
      res = Rack::MockRequest.new(logged).post('/mcp', input: JSON.generate(read), 'HTTP_AUTHORIZATION' => "Bearer #{@secret}",
                                                       'CONTENT_TYPE' => 'application/json')
      assert_includes res.body, 'diary entry'
      Rack::MockRequest.new(logged).post('/mcp', input: '{}', 'HTTP_AUTHORIZATION' => "Bearer #{@secret}x")
    end
    log = out + errors.string
    refute_includes log, @secret
    refute_includes log, 'diary'
    assert_includes out, 'mcp token=claude'
    assert_includes out, 'mcp auth failed'
    assert_includes errors.string, 'POST /mcp '
  end

  # ALLOWED_VAULTS is the sync API's: MCP goes by its tokens' grants alone
  def test_allowed_vaults_dont_limit_mcp
    ENV['ALLOWED_VAULTS'] = 'other'
    assert_equal GRANTS.size, ok('list_access').size
    ok('write_file', path: 'Inbox/allowed', content: 'x')
  ensure
    ENV['ALLOWED_VAULTS'] = ''
  end

end
