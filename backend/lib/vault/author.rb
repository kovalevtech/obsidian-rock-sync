class Vault
  # Who a commit is for: a device (sync API) or a scoped token (MCP), by its name — git author `<name> <name@device>` /
  # `<name> <name@token>`; the committer stays the server — and the client's software (X-Rock-Sync-Client, or
  # `mcp`) → a `Client:` trailer
  Author = Data.define(:name, :kind, :client) do
    # kind: 'device' | 'token'. client: printable ASCII only — a CR / LF in the header can't add lines to the message —
    # at most 200 chars
    def initialize(name:, kind:, client: nil)
      raise ArgumentError, "bad author kind #{kind.inspect}" unless self.class::KINDS.include?(kind)

      client = client.to_s.b.delete('^ -~')[0, 200]
      super(name:, kind:, client: client.empty? ? nil : client)
    end

    def email = "#{name}@#{kind}"
  end

  class Author
    KINDS = %w[device token].freeze
    MCP_CLIENT = 'mcp' # McpTools' trailer

    # A commit's author as the tools show it: { kind: device | token | unknown, name }. Commits from before the kind was
    # in the email (`<name>@vault-sync`) tell it by their trailer: MCP's said `mcp`. Anything else (the server's own
    # commits) is unknown
    def self.of(name:, email:, client:)
      host = email.to_s[/@([^@]*)\z/, 1]
      kind = if KINDS.include?(host) then host
             elsif host == 'vault-sync' then client.to_s.split(',').include?(MCP_CLIENT) ? 'token' : 'device'
             else 'unknown'
             end
      { kind:, name: }
    end
  end
end
