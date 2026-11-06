require_relative 'test_helper'
require 'net/http'
require 'rbconfig'
require 'rotp'
require 'socket'
require 'timeout'

# Several server processes on one VAULTS_DIR / DB_DIR, as the image runs them apart (ENABLED_APPS): real Puma
# subprocesses in production mode, on ports 9500–9599, talking HTTP. Run in the temp dir: no .env files
class ProcessesTest < VaultTest
  CONFIG_RU = File.expand_path('../config.ru', __dir__)
  PORTS = (9500..9599).freeze
  BOOT_TIMEOUT = 30 # s

  def setup
    super
    @servers = []
  end

  def teardown
    @servers.each { stop(_1) }
    super
  end

  # A Puma serving apps on a free port → { pid:, port:, log: }; waits until /health answers
  def start(apps, vaults_dir: @vaults_dir, db_dir: @root, wait: true)
    port = free_port
    log = File.join(@root, "puma-#{port}.log")
    env = {
      'ENABLED_APPS' => apps, 'MCP_ENABLED' => nil, 'RACK_ENV' => 'production', 'VAULTS_DIR' => vaults_dir,
      'DB_DIR' => db_dir, 'ZEITWERK_RELOAD' => 'false', 'VERBOSE_HTTP_LOGS' => 'false',
      'INIT_VAULT_NAME' => nil, 'INIT_VAULT_CODE' => nil
    }
    env.merge!(Config::ADMIN_ENV.to_h { [_1, nil] }) unless apps.include?('admin')
    puma = Gem.bin_path('puma', 'puma')
    pid = Process.spawn(env, RbConfig.ruby, '-rbundler/setup', puma, '-b', "tcp://127.0.0.1:#{port}", '-t', '0:16',
                        '-e', 'production', CONFIG_RU, chdir: @root, out: log, err: log, pgroup: true)
    server = { pid:, port:, log: }
    @servers << server
    wait_until_up(server) if wait
    server
  end

  def wait_until_up(server)
    deadline = Time.now + BOOT_TIMEOUT
    loop do
      flunk "server on #{server[:port]} exited:\n#{File.read(server[:log])}" if Process.waitpid(server[:pid], Process::WNOHANG)
      return if (request(server, Net::HTTP::Get.new('/health')).code == '200' rescue false)
      flunk "server on #{server[:port]} not up:\n#{File.read(server[:log])}" if Time.now > deadline
      sleep 0.1
    end
  end

  def stop(server)
    Process.kill('TERM', server[:pid])
    Timeout.timeout(10) { Process.wait(server[:pid]) }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  rescue Timeout::Error
    Process.kill('KILL', server[:pid])
    Process.wait(server[:pid])
  end

  def free_port
    PORTS.to_a.shuffle.find do |port|
      next false if @servers.any? { _1[:port] == port }

      TCPServer.new('127.0.0.1', port).close
      true
    rescue SystemCallError
      false
    end or flunk 'no free port in 9500–9599'
  end

  def request(server, req, timeout: 30)
    Net::HTTP.start('127.0.0.1', server[:port], read_timeout: timeout) { _1.request(req) }
  end

  def basic(req, vault: 'test', token: @token)
    req.basic_auth(vault, token)
    req
  end

  def put_file(server, path, content, vault: 'test', token: @token)
    req = basic(Net::HTTP::Put.new("/files/#{path}"), vault:, token:)
    req['If-None-Match'] = '*'
    req['Content-Type'] = 'text/markdown'
    req.body = content
    request(server, req)
  end

  # MCP tools/call → the tool's result (JSON)
  def mcp_tool(server, secret, name, **arguments)
    req = Net::HTTP::Post.new('/mcp')
    req['Authorization'] = "Bearer #{secret}"
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json, text/event-stream'
    req.body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name:, arguments: })
    res = request(server, req)
    assert_equal '200', res.code, res.body
    result = JSON.parse(res.body).fetch('result')
    refute result['isError'], result.dig('content', 0, 'text')
    JSON.parse(result.dig('content', 0, 'text'))
  end

  def scoped_secret
    Devices.create_scoped(name: 'claude', grants: [{ vault: 'test', folder: '', mode: 'rw' }]).last
  end

  def logs = @servers.map { File.read(_1[:log]) }.join

  # The sync API in one process, MCP in another, writing the same vault at once: every write a commit of its own, none
  # lost to git's index.lock
  def test_parallel_writes_from_two_processes
    sync = start('sync')
    mcp = start('mcp')
    secret = scoped_secret
    count = 12

    threads = count.times.flat_map do |i|
      [Thread.new { put_file(sync, "sync-#{i}.md", "sync #{i}\n").code },
       Thread.new { mcp_tool(mcp, secret, 'write_file', path: "mcp-#{i}", content: "mcp #{i}\n")['status'] }]
    end
    results = threads.map(&:value)

    assert_equal [['204', 'written']] * count, results.each_slice(2).to_a
    assert_equal 2 * count, commit_count
    assert_equal 0, git('rev-list', '--min-parents=2', '--count', 'HEAD').to_i, 'linear history'
    files = git('ls-tree', '-r', '--name-only', 'HEAD').split("\n").sort
    assert_equal (count.times.map { "sync-#{_1}.md" } + count.times.map { "mcp-#{_1}.md" }).sort, files
    assert_equal files.sort, (Dir.children(File.join(@vaults_dir, 'test', 'tree')) - ['.git']).sort
    refute File.exist?(File.join(@vaults_dir, 'test', 'repo.git', 'index.lock'))
    refute_match(/index\.lock|Git::Error/, logs)
  end

  # Another process's commit: no notify reaches this one, the wait's re-check does
  def test_a_long_poll_hears_a_commit_of_another_process
    commit_file('a.md', "a\n")
    sync = start('sync')
    mcp = start('mcp')
    secret = scoped_secret

    etag = request(sync, basic(Net::HTTP::Get.new('/manifest?v=1')))['ETag']
    answered = nil
    poll = Thread.new do
      req = basic(Net::HTTP::Get.new('/manifest?v=1&wait=30'))
      req['If-None-Match'] = etag
      res = request(sync, req)
      answered = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res
    end
    sleep 0.5 # the poll is waiting
    assert_nil answered

    mcp_tool(mcp, secret, 'write_file', path: 'b', content: "b\n")
    written = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    res = poll.value
    assert_equal '200', res.code
    assert_includes JSON.parse(res.body)['files'].keys, 'b.md'
    assert_operator answered - written, :<=, ChangeFeed::RECHECK + 1
  end

  # A vault the admin process creates: the sync process finds it at the next request, no restart
  def test_a_vault_made_by_the_admin_process_works_in_the_sync_process
    sync = start('sync')
    admin = start('admin')
    assert_equal '401', request(sync, basic(Net::HTTP::Get.new('/manifest'), vault: 'notes')).code

    cookie, csrf = admin_login(admin)
    req = Net::HTTP::Post.new('/admin/vaults')
    req['Cookie'] = cookie
    req['X-Forwarded-Proto'] = 'https'
    req.set_form_data('name' => 'notes', 'authenticity_token' => csrf)
    assert_equal '303', request(admin, req).code
    assert Dir.exist?(File.join(@vaults_dir, 'notes', 'repo.git'))

    token = add_token('pixel', 'notes')
    assert_equal '204', put_file(sync, 'a.md', "a\n", vault: 'notes', token:).code
    assert_equal "a\n", File.read(tree_file('a.md', vault: 'notes'))
  end

  # The session cookie is secure in production: X-Forwarded-Proto as from a TLS proxy. → [cookie, a CSRF token]
  def admin_login(admin)
    get = lambda do |path, cookie|
      req = Net::HTTP::Get.new(path)
      req['Cookie'] = cookie if cookie
      req['X-Forwarded-Proto'] = 'https'
      request(admin, req)
    end
    csrf_of = ->(res) { res.body[/name="authenticity_token" value="([^"]+)"/, 1] }
    cookie_of = ->(res) { res['Set-Cookie'][/\Avault_sync_admin=[^;]+/] }

    page = get.call('/admin/login', nil)
    req = Net::HTTP::Post.new('/admin/login')
    req['Cookie'] = cookie_of.call(page)
    req['X-Forwarded-Proto'] = 'https'
    req.set_form_data('user' => ENV.fetch('ADMIN_USER'), 'password' => ENV.fetch('ADMIN_PASSWORD'),
                      'code' => ROTP::TOTP.new(ENV.fetch('ADMIN_TOTP_SECRET')).now,
                      'authenticity_token' => csrf_of.call(page))
    res = request(admin, req)
    assert_equal '303', res.code, res.body
    cookie = cookie_of.call(res)
    vaults = get.call('/admin/vaults', cookie)
    assert_equal '200', vaults.code
    [vaults['Set-Cookie'] ? cookie_of.call(vaults) : cookie, csrf_of.call(vaults)]
  end

  # The review's way into /admin, sent as is: a process without admin has no Admin to reach
  def test_admin_paths_sent_raw_to_a_sync_process
    sync = start('sync')
    ['/admin/../files/a%2f..%2f..%2flogin', '//admin/login', '/admin//login', '/admin/./login'].each do |path|
      TCPSocket.open('127.0.0.1', sync[:port]) do |socket|
        socket.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        assert_equal 'HTTP/1.1 401 Unauthorized', socket.gets.chomp, path
      end
    end
  end

  # Two processes starting together on an empty DB_DIR: one migrates, the other waits and finds the schema current
  def test_two_first_boots_on_an_empty_db_dir
    vaults_dir = File.join(@root, 'fresh-vaults')
    db_dir = File.join(@root, 'fresh-db')
    [vaults_dir, db_dir].each { Dir.mkdir(_1) }
    servers = [start('sync', vaults_dir:, db_dir:, wait: false), start('mcp', vaults_dir:, db_dir:, wait: false)]
    servers.each { wait_until_up(_1) }

    db = Sequel.sqlite(File.join(db_dir, 'vault-sync.db'))
    assert_equal Dir[File.join(DB::MIGRATIONS, '*.rb')].size, db[:schema_info].get(:version)
    db.disconnect
    assert_equal '401', request(servers.first, basic(Net::HTTP::Get.new('/manifest'))).code
    refute_match(/Error|not starting/, logs)
  end
end
