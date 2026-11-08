# frozen_string_literal: true

# Downloader against a local TLS server whose certificate names HOSTS: a test resolver sends them to 127.0.0.1, and the
# public-address check lets that one address through. Everything else as in production: the URL rules, the host
# list, redirects checked again, private addresses, sizes, statuses, certificates
require_relative 'test_helper'
require 'openssl'
require 'socket'

class DownloaderTest < Minitest::Test
  HOSTS = %w[files.example.com cdn.example.com other.example.org].freeze
  LISTED = %w[files.example.com cdn.example.com].freeze
  PNG = "\x89PNG\r\n\x1A\n\0\0\0\rIHDR".b

  def setup
    key = OpenSSL::PKey::EC.generate('prime256v1')
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=files.example.com')
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(extensions.create_extension('subjectAltName', HOSTS.map { "DNS:#{_1}" }.join(','), false))
    cert.add_extension(extensions.create_extension('basicConstraints', 'CA:TRUE', true))
    cert.sign(key, 'SHA256')
    @store = OpenSSL::X509::Store.new
    @store.add_cert(cert)

    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = key
    tcp = TCPServer.new('127.0.0.1', 0)
    @port = tcp.addr[1]
    @server = OpenSSL::SSL::SSLServer.new(tcp, context)
    @requests = [] # [host, path, headers]
    @routes = {}
    @thread = Thread.new do
      loop do
        serve(@server.accept)
      rescue OpenSSL::SSL::SSLError, SystemCallError
        break if @stopping

        next
      rescue IOError
        break
      end
    end
  end

  def teardown
    @stopping = true
    @server.close
    @thread.join(2)
  end

  # One request per connection: the route's [status, headers, body], a body given as chunks sent chunked
  def serve(conn)
    path = conn.gets.to_s.split[1]
    headers = {}
    while (line = conn.gets) && line != "\r\n"
      name, value = line.chomp.split(': ', 2)
      headers[name.downcase] = value
    end
    @requests << [headers['host'].to_s.split(':').first, path, headers]
    status, extra, body = @routes.fetch(path) { [404, {}, 'nope'] }
    head = extra.merge('Connection' => 'close')
    head['Content-Length'] = body.bytesize.to_s if body.is_a?(String) && !head.key?('Content-Length')
    head['Transfer-Encoding'] = 'chunked' if body.is_a?(Array)
    conn.write("HTTP/1.1 #{status} X\r\n#{head.map { "#{_1}: #{_2}\r\n" }.join}\r\n")
    if body.is_a?(Array)
      body.each { conn.write("#{_1.bytesize.to_s(16)}\r\n#{_1}\r\n") }
      conn.write("0\r\n\r\n")
    else
      conn.write(body)
    end
  rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
    nil
  ensure
    conn&.close rescue nil
  end

  def downloader(resolve: ->(host) { HOSTS.include?(host) ? ['127.0.0.1'] : [] },
                 public_ip: ->(ip) { ip == '127.0.0.1' || Downloader.public?(ip) }, cert_store: @store)
    Downloader.new(resolver: resolve, public_ip:, port: @port, cert_store:)
  end

  def fetch(url, hosts: LISTED, max: 1000, **options)
    downloader(**options).fetch(url, allowed: ->(host) { DownloadHosts.allowed?(host, hosts) }, max:)
  end

  def refused(url, **options)
    assert_raises(Downloader::Refused) { fetch(url, **options) }.message
  end

  def test_public_addresses
    %w[8.8.8.8 1.1.1.1 93.184.216.34 172.32.0.1 100.128.0.1 2606:4700:4700::1111 2a00:1450:4001::1].each do
      assert Downloader.public?(_1), _1
    end
    %w[127.0.0.1 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 100.64.0.1 100.101.102.103 169.254.169.254 0.0.0.0
       224.0.0.1 255.255.255.255 198.18.0.1 192.0.2.1 ::1 :: fe80::1 fc00::1 fd12:3456::1 ff02::1 ::ffff:127.0.0.1
       ::ffff:10.0.0.1 64:ff9b::a00:1 2002:a00:1:: 2001:db8::1 2001:0:1::1 nonsense].each do
      refute Downloader.public?(_1), _1
    end
  end

  def test_downloads_a_file
    @routes['/a.png'] = [200, { 'Content-Type' => 'image/png' }, PNG]
    result = fetch('https://files.example.com/a.png')
    assert_equal [PNG, 'image/png'], [result.body, result.content_type]
    assert_equal Encoding::BINARY, result.body.encoding
    host, path, headers = @requests.last
    assert_equal ['files.example.com', '/a.png'], [host, path]
    assert_equal ['identity', Downloader::USER_AGENT], headers.values_at('accept-encoding', 'user-agent')
    assert_nil headers['cookie']
    assert_nil headers['authorization']
    assert_equal PNG, fetch('https://FILES.example.com./a.png').body, 'case and a trailing dot'
  end

  def test_only_hosts_on_the_list
    refusal = assert_raises(Downloader::HostNotApproved) { fetch('https://other.example.org/x?a=1') }
    assert_equal ['other.example.org', 'https://other.example.org/x?a=1'], [refusal.host, refusal.url]
    assert_includes refusal.message, "`other.example.org` isn't an approved download host"
    assert_raises(Downloader::HostNotApproved) { fetch('https://files.example.com/x', hosts: []) }
    assert_includes refused('https://files.example.com/x', hosts: ['*.example.com']), 'answered 404'
    assert_includes refused('https://example.com/x', hosts: ['*.example.com']), "isn't an approved download host"
    assert_empty @requests.select { _1[0] != 'files.example.com' }, 'nothing sent to hosts off the list'
  end

  def test_url_rules
    {
      'http://files.example.com/a.png' => 'only https',
      'ftp://files.example.com/a.png' => 'only https',
      'https://user:pw@files.example.com/a.png' => 'no user or password',
      'https://files.example.com:8443/a.png' => 'only port 443',
      'not a url' => "isn't",
      'https://' => "isn't",
      'https://exa mple.com/' => "isn't a URL"
    }.each { |url, why| assert_includes refused(url), why, url }
    assert_empty @requests
  end

  # Each hop: https, on the list, public. A relative Location resolves against the last URL
  def test_redirects_are_checked_again
    @routes['/a.png'] = [200, { 'Content-Type' => 'image/png' }, PNG]
    @routes['/to-cdn'] = [302, { 'Location' => 'https://cdn.example.com/a.png' }, '']
    @routes['/relative'] = [301, { 'Location' => '/a.png' }, '']
    @routes['/to-other'] = [302, { 'Location' => 'https://other.example.org/a.png' }, '']
    @routes['/to-http'] = [307, { 'Location' => 'http://files.example.com/a.png' }, '']
    @routes['/loop'] = [302, { 'Location' => '/loop' }, '']
    @routes['/nowhere'] = [302, {}, '']
    assert_equal PNG, fetch('https://files.example.com/to-cdn').body
    assert_equal 'cdn.example.com', @requests.last[0]
    assert_equal PNG, fetch('https://files.example.com/relative').body
    refusal = assert_raises(Downloader::HostNotApproved) { fetch('https://files.example.com/to-other') }
    assert_equal ['other.example.org', 'https://other.example.org/a.png'], [refusal.host, refusal.url], 'the redirect\'s'
    assert_includes refused('https://files.example.com/to-http'), 'only https'
    assert_includes refused('https://files.example.com/loop'), 'More than 5 redirects'
    assert_includes refused('https://files.example.com/nowhere'), 'redirected nowhere'
    assert_empty @requests.select { _1[0] == 'other.example.org' }
    private_cdn = ->(host) { host == 'cdn.example.com' ? ['10.0.0.7'] : ['127.0.0.1'] }
    assert_includes refused('https://files.example.com/to-cdn', resolve: private_cdn), 'points into a private network'
  end

  # Not one private address among a host's answers: the connection would go to the checked one, but a host answering
  # with both is a reason to stop
  def test_never_a_private_address
    @routes['/a.png'] = [200, {}, PNG]
    { ['10.0.0.1'] => 'private network', ['127.0.0.1', '192.168.1.1'] => 'private network',
      [] => "doesn't resolve" }.each do |ips, why|
      assert_includes refused('https://files.example.com/a.png', resolve: ->(_) { ips }), why, ips.inspect
    end
    strict = ->(_) { ['127.0.0.1'] }
    assert_includes refused('https://files.example.com/a.png', resolve: strict, public_ip: ->(ip) { Downloader.public?(ip) }),
                    'private network', 'loopback, with the production check'
    assert_empty @requests
  end

  def test_size_limit
    @routes['/fits'] = [200, {}, 'x' * 1000]
    @routes['/big'] = [200, {}, 'x' * 1001]
    @routes['/drip'] = [200, {}, Array.new(20) { 'x' * 100 }]
    @routes['/drip-fits'] = [200, {}, Array.new(10) { 'x' * 100 }]
    assert_equal 1000, fetch('https://files.example.com/fits').body.bytesize
    assert_equal 1000, fetch('https://files.example.com/drip-fits').body.bytesize
    assert_includes refused('https://files.example.com/big'), 'is 1001 bytes, at most 1000'
    assert_includes refused('https://files.example.com/drip'), 'is over 1000 bytes, at most 1000'
  end

  def test_only_200_is_a_file
    @routes['/gone'] = [410, {}, '']
    @routes['/partial'] = [206, {}, 'x']
    assert_includes refused('https://files.example.com/missing'), '`files.example.com` answered 404'
    assert_includes refused('https://files.example.com/gone'), 'answered 410'
    assert_includes refused('https://files.example.com/partial'), 'answered 206'
  end

  def test_an_invalid_certificate
    @routes['/a.png'] = [200, {}, PNG]
    assert_includes refused('https://files.example.com/a.png', cert_store: OpenSSL::X509::Store.new), "certificate isn't valid"
  end
end
