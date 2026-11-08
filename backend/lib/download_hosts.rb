# The hosts MCP's download_file may fetch from: the admin's list (DB[:download_hosts]). An entry is a host
# (`example.com`: that host only) or `*.example.com` (its subdomains, not example.com itself). Empty: no downloads — a
# refusal names the host for the user to approve. Read per call, nothing cached: the admin may run in another process.
# Whatever Claude puts into a URL reaches its host (a prompt injection could put a note there): the list is the hosts
# trusted with that, which is why it's the admin's and not Claude's
module DownloadHosts
  Host = Data.define(:id, :host, :created_at)
  LABEL = /[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/
  # Labels, dots, a TLD starting with a letter (no IP addresses, no `localhost`), ASCII (punycode for the rest)
  FORMAT = /\A(?:\*\.)?(?:#{LABEL}\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  MAX = 253

  def self.list = DB[:download_hosts].order(:host).map { Host.new(**_1) }
  def self.hosts = DB[:download_hosts].order(:host).select_map(:host)

  # What the admin typed → the entry: lowercase, no trailing dot; a URL pasted stands for its host
  def self.normalize(typed)
    text = typed.to_s.strip.downcase
    text = (URI.parse(text).host.to_s rescue '') if text.include?('://')
    text.chomp('.')
  end

  # → [host, nil] once on the list (it may have been there), or [nil, why not]
  def self.add(typed)
    host = normalize(typed)
    unless host.length <= MAX && host.match?(FORMAT)
      return [nil, "`#{typed.to_s.strip}` isn't a host name: like `example.com`, or `*.example.com` for its subdomains."]
    end

    DB[:download_hosts].insert_conflict.insert(host:, created_at: Time.now.utc)
    [host, nil]
  end

  def self.remove(id) = DB[:download_hosts].where(id:).delete

  # host (lowercase, as a URI gives it): on the list, as itself or under a `*.` entry
  def self.allowed?(host, hosts = self.hosts)
    host = host.to_s.downcase.chomp('.')
    hosts.any? { |entry| entry.start_with?('*.') ? host.end_with?(entry[1..]) : host == entry }
  end
end
