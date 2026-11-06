require_relative 'test_helper'
require 'rbconfig'
require 'socket'

# CanonicalPath (config.ru's first middleware): raw request lines to a real Puma running config.ru — rack-test and
# Net::HTTP would normalize what's being tested. Admin and MCP mounted, request log on
class CanonicalPathTest < VaultTest
  CONFIG_RU = File.expand_path('../config.ru', __dir__)
  PORTS = 9600..9699

  # The security review's bypass and its variants: each → 400, empty body, one log line without the query
  REFUSED = [
    'GET /admin/../files/a%2f..%2f..%2flogin',
    'POST /admin/../files/a%2f..%2f..%2flogin',
    'POST /mcp/../files/a%2f..%2f..%2fmcp',
    'GET //admin/login',
    'GET /admin//login',
    'GET /admin/./login',
    'GET /admin/../x',
    'GET /admin/.',
    'GET /files/a%2fb.md',
    'GET /files/a%2Fb.md',
    'GET /files/a%5cb.md',
    'GET /files/a%5Cb.md',
    'GET /files/a\\b.md',
    'GET /files/%2e%2e/x.md',
    'GET /files/%2E%2E/x.md',
    'GET /files/a%2eb.md',
    'GET /files/a%00.md',
    'GET /files/a%0d%0aX-Injected:%20y',
    'GET /files/a%7f.md',
    'GET /files/a%zz.md',
    'GET /files/a%',
    'GET //health',
    'GET http://localhost/admin/login',
    'POST http://localhost/mcp',
    'OPTIONS *'
  ].freeze

  # Canonical: through to the apps as before (401 without a token)
  PASSING = {
    'GET /files/a%20b.md' => 401,
    'GET /files/%D0%B7%D0%B0%D0%BC%D0%B5%D1%82%D0%BA%D0%B0.md' => 401, # заметка
    'GET /files/%25.md' => 401,
    'GET /files/%252f.md' => 401, # `%2f` typed in a name
    'GET /files/a..b.md' => 401,
    'GET /files/%F0%9F%93%9D%20note.md' => 401,
    'GET /files/a;b%3Fc%23d.md' => 401,
    'PATCH /files/a.md' => 401,
    'GET /manifest?v=1&wait=25' => 401,
    'GET /ADMIN/login' => 401,
    'GET /health' => 200,
    'GET /admin/login' => 200
  }.freeze

  def setup
    super
    @log = File.join(@root, 'puma.log')
    @port = PORTS.find { |port| TCPServer.new('127.0.0.1', port).close || true rescue false } or skip('no free port')
    env = { 'VAULTS_DIR' => @vaults_dir, 'DB_DIR' => @root, 'RACK_ENV' => 'production', 'VERBOSE_HTTP_LOGS' => 'true' }
    @pid = Process.spawn(env, RbConfig.ruby, '-rbundler/setup', Gem.bin_path('puma', 'puma'),
                         '-b', "tcp://127.0.0.1:#{@port}", CONFIG_RU, chdir: @root, out: @log, err: @log)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    until (TCPSocket.new('127.0.0.1', @port).close || true rescue false)
      flunk "puma didn't start: #{File.read(@log)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
  end

  def teardown
    Process.kill('KILL', @pid) if @pid
    Process.wait(@pid) if @pid
    super
  end

  # One raw request: [status, body, what the server logged meanwhile]
  def send_raw(request_line, headers = '')
    logged = File.size(@log)
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write("#{request_line} HTTP/1.1\r\nHost: localhost\r\n#{headers}Content-Length: 0\r\nConnection: close\r\n\r\n".b)
    head, body = socket.read.split("\r\n\r\n", 2)
    socket.close
    [head[%r{\AHTTP/1\.[01] (\d+)}, 1].to_i, body, File.binread(@log)[logged..]]
  end

  def test_non_canonical_paths_are_refused_before_anything
    REFUSED.each do |line|
      status, body, logged = send_raw(line.end_with?('*') ? line : "#{line}?code=123456")
      assert_equal 400, status, line
      assert_equal '', body, line
      method, path = line.split(' ', 2)
      assert_equal %(vault-sync: refused a non-canonical path: #{method} #{path.inspect}\n), logged, line
    end
  end

  # Puma refuses raw control characters itself, before Rack: at most a line of its own
  def test_raw_control_characters_never_reach_rack
    ["GET /files/a\x00.md", "GET /files/a\x01.md", "GET /files/a\x7f.md"].each do |line|
      status, _, logged = send_raw(line)
      assert_equal 400, status, line.inspect
      assert_operator logged.lines.size, :<=, 1, logged # Puma's parse error, maybe written after the answer
      refute_match(/vault-sync:|<-- /, logged)
    end
  end

  def test_canonical_paths_pass_untouched
    PASSING.each do |line, expected|
      status, _, logged = send_raw(line)
      assert_equal expected, status, line
      refute_includes logged, 'non-canonical', line
    end
    auth = "Authorization: Basic #{["test:#{@token}"].pack('m0')}\r\nX-Rock-Sync-Vault: test\r\n"
    assert_equal 200, send_raw('GET /manifest?v=1', auth).first
  end

  def test_rules
    ['/', '/a', '/a/', '/files/a%20b.md', '/files/%D0%B0.md', '/files/%25.md', '/files/%252f.md', '/files/a..b.md',
     '/files/...', '/files/.keep', '/files/a/.keep', '/admin/', '/mcp', "/files/\xD0\xB0.md".b].each do |path|
      assert CanonicalPath.canonical?(path), path
    end
    ['', '*', 'a', 'http://h/x', '//', '//a', '/a//', '/a//b', '/.', '/..', '/a/./b', '/a/../b', '/a/.', '/a/..',
     '/a%2fb', '/a%2Fb', '/a%5cb', '/a%5Cb', '/a%2eb', '/a%2Eb', '/a\\b', '/a%00', '/a%0A', '/a%1f', '/a%7F', '/a%C2%85',
     "/a\x00", "/a\n", '/a%zz', '/a%', '/a%2', '/a%%32f'].each do |path|
      refute CanonicalPath.canonical?(path), path.inspect
    end
  end
end
