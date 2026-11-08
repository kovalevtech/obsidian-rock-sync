require 'ipaddr'
require 'net/http'
require 'openssl'
require 'socket'

# MCP's download_file: one GET over https from a host on the admin's list (DownloadHosts), at most `max` bytes. Never to
# an address that isn't the public internet: the server sits inside a home network, a tailnet, Docker's network, and a
# URL must not reach what the internet can't (SSRF). So every address of the host is checked, the connection goes to
# the checked one (no second DNS answer in between), and each redirect is checked again: https, on the list, public.
# No proxy from the environment, no cookies, no credentials. Refusals: Downloader::Refused, a message Claude can act on
class Downloader
  class Refused < StandardError; end

  Result = Data.define(:body, :content_type)

  MAX_REDIRECTS = 5
  OPEN_TIMEOUT = 5 # s
  READ_TIMEOUT = 15 # s, waiting for the next bytes
  DEADLINE = 60 # s, the whole download, redirects included
  USER_AGENT = 'rock-sync (MCP download_file)'.freeze

  # IPv4 that isn't the public internet: this network, private, Tailscale's / CGNAT, loopback, link-local (cloud
  # metadata), IETF / documentation / benchmarking ranges, 6to4 relays, multicast, reserved. IPv6: global unicast
  # (2000::/3) only, minus Teredo, documentation and 6to4 (both carry an IPv4 address); IPv4-mapped ones as IPv4
  BLOCKED = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
    192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    2001::/32 2001:db8::/32 2002::/16
  ].map { IPAddr.new(_1) }.freeze
  GLOBAL_V6 = IPAddr.new('2000::/3')

  def self.public?(ip)
    ip = IPAddr.new(ip.to_s).native
    return false if BLOCKED.any? { _1.family == ip.family && _1.include?(ip) }

    ip.ipv4? || GLOBAL_V6.include?(ip)
  rescue IPAddr::Error
    false
  end

  # resolver: host → its addresses; public_ip: address → may be connected to; port, cert_store: tests' (a local TLS
  # server: an https URL still names no port, and 443 is the only one it may)
  def initialize(resolver: ->(host) { Addrinfo.getaddrinfo(host, 443, nil, :STREAM).map(&:ip_address).uniq },
                 public_ip: ->(ip) { Downloader.public?(ip) }, port: 443, cert_store: nil)
    @resolver = resolver
    @public_ip = public_ip
    @port = port
    @cert_store = cert_store
  end

  # → Result. allowed: host → on the list?; max: bytes
  def fetch(url, allowed:, max:)
    deadline = now + DEADLINE
    uri = parse(url)
    (MAX_REDIRECTS + 1).times do
      check(uri, allowed)
      result = get(uri, address(uri.host), max, deadline)
      return result if result.is_a?(Result)

      uri = redirect(uri, result)
    end
    raise Refused, "More than #{MAX_REDIRECTS} redirects: nothing downloaded."
  end

  private

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def parse(url)
    uri = URI.parse(url.to_s.strip)
    unless uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty?
      raise Refused, "`#{url}` isn't an https URL: only https can be downloaded."
    end

    uri
  rescue URI::InvalidURIError
    raise Refused, "`#{url}` isn't a URL."
  end

  # Every hop: https on its own port, no credentials in it, a host on the list (lowercase, no trailing dot: as listed,
  # and as the certificate names it)
  def check(uri, allowed)
    raise Refused, "`#{uri}`: only https can be downloaded." unless uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty?
    raise Refused, "`#{uri}`: no user or password in a download's URL." if uri.userinfo
    raise Refused, "`#{uri}`: only port 443." unless uri.port == 443

    uri.host = uri.host.downcase.chomp('.')
    return if allowed.call(uri.host)

    raise Refused, "`#{uri.host}` isn't on the user's list of download hosts (the admin panel, Download hosts): ask " \
                   'the user to add it, or download from a host on the list.'
  end

  # The address to connect to: all of the host's must be public (one private answer among them is a reason to stop)
  def address(host)
    ips = begin
      @resolver.call(host)
    rescue SocketError
      []
    end
    raise Refused, "`#{host}` doesn't resolve: nothing downloaded." if ips.empty?
    raise Refused, "`#{host}` points into a private network: nothing downloaded." unless ips.all? { @public_ip.call(_1) }

    ips.first
  end

  # → Result, or the Location of a redirect
  def get(uri, ip, max, deadline)
    http = Net::HTTP.new(uri.host, @port, nil) # nil: no proxy, whatever the environment says
    http.ipaddr = ip
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.verify_hostname = true
    http.cert_store = @cert_store if @cert_store
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http.write_timeout = READ_TIMEOUT
    request = Net::HTTP::Get.new(uri.request_uri, 'User-Agent' => USER_AGENT, 'Accept' => '*/*',
                                                  'Accept-Encoding' => 'identity')
    http.start do
      http.request(request) do |response|
        return response['location'].to_s if response.is_a?(Net::HTTPRedirection)
        raise Refused, "`#{uri.host}` answered #{response.code}: nothing downloaded." unless response.is_a?(Net::HTTPOK)

        return Result.new(body: read(response, uri, max, deadline), content_type: response['content-type'].to_s)
      end
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
    raise Refused, "`#{uri.host}` took too long: nothing downloaded."
  rescue OpenSSL::SSL::SSLError
    raise Refused, "`#{uri.host}`'s certificate isn't valid: nothing downloaded."
  rescue SocketError, SystemCallError, IOError, EOFError, Net::HTTPBadResponse
    raise Refused, "Couldn't reach `#{uri.host}`: nothing downloaded."
  end

  # The body, refused as soon as it's over max: by its Content-Length, else while it comes
  def read(response, uri, max, deadline)
    length = response['content-length']
    raise Refused, too_big(uri, length.to_i, max) if length.to_i > max

    body = String.new(capacity: [length.to_i, max].min, encoding: Encoding::BINARY)
    response.read_body do |chunk|
      body << chunk
      raise Refused, too_big(uri, "over #{max}", max) if body.bytesize > max
      raise Refused, "`#{uri.host}` took too long: nothing downloaded." if now > deadline
    end
    body
  end

  def too_big(uri, size, max) = "`#{uri}` is #{size} bytes, at most #{max} can be downloaded: nothing downloaded."

  def redirect(uri, location)
    raise Refused, "`#{uri.host}` redirected nowhere: nothing downloaded." if location.empty?

    uri.merge(location).tap { _1.fragment = nil }
  rescue URI::Error
    raise Refused, "`#{uri.host}` redirected to `#{location}`, not a URL: nothing downloaded."
  end
end
