# frozen_string_literal: false
# Nothing a client sends changes how the server's git behaves (CLAUDE.md "Decisions": the vault path rule, git
# independent of vault files, failed writes leave nothing): refused paths through the sync API and MCP, names git would
# read as pathspecs, files planted in tree/ (.gitignore, .gitattributes, nested repos), commits that fail
require_relative 'test_helper'
require_relative '../mcp_endpoint'
require 'json'

class GitIsolationTest < VaultTest
  include Rack::Test::Methods

  def app
    Rack::Builder.new do
      map('/mcp') { run McpEndpoint }
      run App
    end
  end

  def setup
    super
    McpTools::RATE.reset
    @a = commit_file('a.md', "a\n")
    @b = commit_file('b.md', "b\n")
    basic_authorize('test', @token)
  end

  # What the vault holds: HEAD and every file (and folder) in tree/
  def snapshot
    files = Dir.glob('**/*', File::FNM_DOTMATCH, base: @vault.tree).reject { %w[. ..].include?(File.basename(_1)) }
    [git('rev-parse', 'HEAD').chomp, files.sort.to_h { [_1, File.file?(tree_file(_1)) ? File.binread(tree_file(_1)) : :dir] }]
  end

  def url(path) = path.split('/', -1).map { URI.encode_uri_component(_1) }.join('/')
  def put_file(path, body, env = {}) = put("/files/#{url(path)}", body, { 'CONTENT_TYPE' => 'text/markdown' }.merge(env))
  def move(from, to) = post("/move/#{url(from)}", nil, 'HTTP_DESTINATION' => url(to))

  def manifest
    get '/manifest', 'v' => '1'
    JSON.parse(last_response.body)['files']
  end

  REFUSED = ['.gitignore', '.gitattributes', '.gitmodules', '.git', '.git/config', 'x/.git/hooks/post-commit', '.GIT',
             '.Git/HEAD', 'x/.GIT', ".\u{200c}git/HEAD", 'git~1/config', '.obsidian/app.json', '.keep/x', "a\0b.md",
             "a\nb.md", 'a\\b.md', '~root/x', '~nosuchuser', "#{'a' * 300}.md", "x/#{'b' * 256}"].freeze

  def test_refused_paths_are_400_on_every_route_and_change_nothing
    before = snapshot
    # Not `a\b.md`: rack-protection turns an encoded backslash into a slash before App sees it (PathTest has it)
    (REFUSED - ['a\\b.md']).each do |path|
      [-> { put_file(path, "x\n", 'HTTP_IF_NONE_MATCH' => '*') }, -> { put_file(path, "x\n", 'HTTP_IF_MATCH' => @a) },
       -> { post "/merge/#{url(path)}", "x\n", 'CONTENT_TYPE' => 'text/markdown', 'HTTP_IF_MATCH' => @a },
       -> { get "/files/#{url(path)}" }, -> { delete "/files/#{url(path)}", nil, 'HTTP_IF_MATCH' => @a },
       -> { move('a.md', path) }, -> { move(path, 'c.md') }].each_with_index do |request, i|
        request.call
        assert_equal 400, last_response.status, "#{path.inspect} request #{i}"
      end
    end
    assert_equal before, snapshot
  end

  # Pathspec magic, globs, options: plain names to git (GIT_LITERAL_PATHSPECS, `--`), each touching only itself
  def test_names_git_could_read_as_pathspecs_are_literal
    names = [':/b.md', ':(exclude)x', ':!a.md', '*', '*.md', '[ab].md', '-rf', '--help', ':(top)a.md']
    names.each do |name|
      assert_equal 204, put_file(name, "#{name}\n", 'HTTP_IF_NONE_MATCH' => '*').status, name
      assert_equal({ 'a.md' => @a, 'b.md' => @b, name => blob("#{name}\n") },
                   @vault.git.ls_tree('HEAD').transform_values(&:first).slice('a.md', 'b.md', name), name)
      get "/files/#{url(name)}"
      assert_equal "#{name}\n", last_response.body
      refute_nil last_response['Last-Modified'], name

      move(name, "moved/#{name}")
      assert_equal 204, last_response.status, name
      delete "/files/#{url("moved/#{name}")}", nil, 'HTTP_IF_MATCH' => blob("#{name}\n")
      assert_equal 204, last_response.status, name
      assert_equal %w[a.md b.md], @vault.git.ls_tree('HEAD').keys, name
      assert_equal %w[a.md b.md], Dir.children(@vault.tree).sort, name
    end
  end

  def test_mcp_refuses_the_same_paths
    _, secret = Devices.create_scoped(name: 'claude', grants: [{ vault: 'test', folder: '', mode: 'rw' }])
    before = snapshot
    REFUSED.each do |path|
      McpTools::RATE.reset
      [['write_file', { content: "x\n" }], ['append_file', { text: 'x' }], ['read_file', {}],
       ['delete_file', { base: @a }], ['list_folder', {}]].each do |name, arguments|
        post '/mcp', JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                   params: { name:, arguments: { path:, **arguments } }),
             'CONTENT_TYPE' => 'application/json', 'HTTP_AUTHORIZATION' => "Bearer #{secret}"
        result = JSON.parse(last_response.body)['result']
        assert result['isError'], "#{name} #{path.inspect}: #{result}"
        text = result.dig('content', 0, 'text')
        # Hidden: not found, as everything MCP may not see; the rest: not a path
        assert_match(/not found|isn't a path/, text)
        assert_match(/not found/, text, path.inspect) if Vault::Path.refusal(path) == :hidden
      end
    end
    assert_equal before, snapshot
  end

  # Planted by hand into tree/ (or committed before the rule): nothing there changes what git stores or runs
  def plant
    marker = File.join(@root, 'ran')
    script = File.join(@root, 'hook.sh')
    File.write(script, "#!/bin/sh\ntouch #{marker}\n")
    File.chmod(0o755, script)
    attributes = "* text eol=crlf working-tree-encoding=UTF-16 filter=x merge=x diff=x -delta\n"
    File.write(tree_file('.gitignore'), "*\n")
    File.write(tree_file('.gitattributes'), attributes)
    @vault.git.commit('OLD', { '.gitignore' => @vault.git.hash_object("*\n"),
                               '.gitattributes' => @vault.git.hash_object(attributes) })
    # A nested repo with a hook and an fsmonitor, and a .git file pointing at it
    nested = tree_file('y')
    system(Git::ENV_ISOLATED, 'git', 'init', '-q', nested, out: File::NULL, exception: true)
    File.open(File.join(nested, '.git', 'config'), 'a') do |config|
      config.puts "[core]\n\tfsmonitor = #{script}\n\thooksPath = #{File.dirname(script)}"
      config.puts "[filter \"x\"]\n\tclean = #{script}\n\tsmudge = #{script}\n[merge \"x\"]\n\tdriver = #{script}"
    end
    %w[pre-commit post-commit post-index-change reference-transaction].each do |hook|
      FileUtils.cp(script, File.join(nested, '.git', 'hooks', hook))
    end
    File.write(tree_file('y/.gitattributes'), attributes)
    File.write(tree_file('.git'), "gitdir: y/.git\n")
    marker
  end

  def assert_stored(path, body)
    assert_equal blob(body), last_response['ETag'], path
    assert_equal [blob(body), body.bytesize], manifest[path], path
    assert_equal body, git('cat-file', 'blob', "HEAD:#{path}"), path
    assert_equal body, File.binread(tree_file(path)), path
  end

  def test_planted_git_files_change_nothing
    marker = plant
    crlf = "one\ntwo\r\nthree\n"
    assert_equal 204, put_file('a.md', crlf, 'HTTP_IF_MATCH' => @a).status
    assert_stored('a.md', crlf)

    assert_equal 204, put_file('y/n.md', "in the nested repo\n", 'HTTP_IF_NONE_MATCH' => '*').status
    assert_stored('y/n.md', "in the nested repo\n")

    # A merge (stale If-Match): the merged text stored as it is
    base = "1\n2\n3\n"
    put_file('m.md', base, 'HTTP_IF_NONE_MATCH' => '*')
    put_file('m.md', "1 server\n2\n3\n", 'HTTP_IF_MATCH' => blob(base))
    assert_equal 200, put_file('m.md', "1\n2\n3 mine\n", 'HTTP_IF_MATCH' => blob(base)).status
    assert_stored('m.md', "1 server\n2\n3 mine\n")
    post '/merge/m.md', "1 server\n2 again\n3 mine\n", 'CONTENT_TYPE' => 'text/markdown', 'HTTP_IF_MATCH' => blob(base)
    assert_equal 409, last_response.status # line 1 changed on both sides since base: merged by git, not a driver

    move('a.md', 'y/sub/a.md')
    assert_equal 204, last_response.status
    assert_stored('y/sub/a.md', crlf)
    refute manifest.key?('a.md')

    delete '/files/y/n.md', nil, 'HTTP_IF_MATCH' => blob("in the nested repo\n")
    assert_equal 204, last_response.status
    refute manifest.key?('y/n.md')
    refute File.exist?(tree_file('y/n.md'))

    refute File.exist?(marker), 'a hook, filter or fsmonitor ran'
    assert_equal "*\n", File.read(tree_file('.gitignore')) # left as it was
  end

  def test_the_boot_log_names_refused_paths
    plant
    out, = capture_io { Vault.check! }
    line = out.lines.grep(/vault test/).first
    assert_match(/holds 5 path\(s\) the server refuses/, line)
    %w[.git .gitattributes .gitignore y/.git/ y/.gitattributes].each { assert_includes line, _1.inspect }
  end

  def test_a_clean_vault_logs_nothing
    out, = capture_io { Vault.check! }
    assert_empty out
  end

  # A path git now refuses (HFS spelling of .git), committed before: the vault still takes writes
  def test_a_vault_holding_a_path_git_refuses_now_still_takes_writes
    hash = @vault.git.hash_object("x\n")
    system(Git::ENV_ISOLATED, 'git', "--git-dir=#{@vault.git.git_dir}", '-c', 'core.protectHFS=false', 'update-index',
           '--add', '--cacheinfo', "100644,#{hash},.\u{200c}git/x", exception: true)
    tree = git('write-tree').chomp
    commit = IO.popen([Git::ENV_ISOLATED, 'git', "--git-dir=#{@vault.git.git_dir}", '-c', 'user.name=old',
                       '-c', 'user.email=old@localhost', 'commit-tree', tree, '-p', 'HEAD', '-m', 'OLD'], &:read).chomp
    git('update-ref', 'HEAD', commit)

    assert_equal 204, put_file('c.md', "c\n", 'HTTP_IF_NONE_MATCH' => '*').status
    assert_includes @vault.git.ls_tree('HEAD').keys, ".\u{200c}git/x"
  end

  # A failing step (the index or the branch locked by someone else) leaves tree/ and HEAD as they were, and nothing of
  # it slips into the next commit
  def test_a_failed_commit_leaves_nothing_behind
    server = commit_file('b.md', "b\nserver\n")
    %w[index.lock refs/heads/main.lock].each do |lock|
      lock = File.join(@vault.git.git_dir, lock)
      FileUtils.touch(lock)
      before = snapshot
      [-> { WriteFile.call(@vault, 'new/deep/n.md', "n\n", if_none_match: '*', keeps: true) },
       -> { WriteFile.call(@vault, 'a.md', "changed\n", if_match: @a) },
       -> { WriteFile.call(@vault, 'b.md', "mine\nb\n", if_match: @b, mergeable: true) }, # merges cleanly
       -> { AppendFile.call(@vault, 'a.md', 'more') },
       -> { MoveFile.call(@vault, 'a.md', 'moved/a.md') },
       -> { DeleteFile.call(@vault, 'a.md', if_match: @a) }].each do |step|
        assert_raises(Git::Error) { step.call }
        assert_equal before, snapshot, lock
      end
      FileUtils.rm(lock)
    end

    assert_equal 204, put_file('c.md', "c\n", 'HTTP_IF_NONE_MATCH' => '*').status
    assert_equal({ 'a.md' => @a, 'b.md' => server, 'c.md' => blob("c\n") }, @vault.git.ls_tree('HEAD').transform_values(&:first))
    assert_equal %w[a.md b.md c.md], Dir.children(@vault.tree).sort
  end
end
