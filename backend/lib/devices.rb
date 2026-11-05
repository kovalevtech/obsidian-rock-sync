require 'digest'
require 'securerandom'

# Tokens (DB[:devices]), of two kinds. `device`: one per device and vault (a connection code connects one), the sync
# API (App), in its vault (devices.vault_id). `scoped`: the MCP endpoint only (McpEndpoint), reaching what its grants
# name (Grants), no vault of its own. Only the
# token's SHA-256 is stored, and a token is looked up by it: random 32 bytes can't be brute-forced, so no salt / bcrypt
# (that would be a bcrypt per entry per request). The token itself is shown once, when created. Revoked tokens keep
# their row. A name is the commit author, for history only: several tokens may share one.
module Devices
  # What App and Vault::Author use. vault: its name, nil for a scoped token
  Device = Data.define(:id, :name, :vault)

  NAME = /\A[a-z0-9-]{1,64}\z/
  SEEN_EVERY = 5 * 60 # s: last_seen_at is written at most this often per device

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  # kind: what the caller serves; a token of the other kind is refused like any other.
  # → [Device, nil] | [nil, :unknown | :revoked | :device | :scoped (the token's kind, when it's the wrong one)]
  def self.authenticate(token, kind: 'device')
    row = rows.where(token_sha256: digest(token)).first
    return [nil, :unknown] unless row
    return [nil, :revoked] if row[:revoked_at]
    return [nil, row[:kind].to_sym] unless row[:kind] == kind

    [Device.new(id: row[:id], name: row[:name], vault: row[:vault]), nil]
  end

  # → [Device, token] (32 random bytes, base64url). ArgumentError: bad name, no such vault
  def self.create(name:, vault:)
    check_name(name)
    vault_id = DB[:vaults].where(name: vault.to_s).get(:id) or raise ArgumentError, "no vault #{vault}"
    insert(name, 'device', new_token, vault_id:) { |id| Device.new(id:, name:, vault:) }
  end

  # A token for the MCP endpoint: no vaults, it reaches what its grants name (rows Grants.check passed, saved with it).
  # → [Device, token], ArgumentError like create
  def self.create_scoped(name:, grants: [])
    check_name(name)
    insert(name, 'scoped', new_token) do |id|
      Grants.replace(id, grants)
      Device.new(id:, name:, vault: nil)
    end
  end

  # The token's row (admin), nil if there's none of that kind
  def self.find(id, kind:) = DB[:devices].where(id:, kind:).first

  # Scoped tokens only (a device's name is in its commits, and its settings): later commits carry the new name.
  # ArgumentError: bad name
  def self.rename(id, name)
    check_name(name)
    DB[:devices].where(id:, kind: 'scoped').update(name:)
  end

  # Reconnect: the device keeps its row, name and vaults; its old token stops working. → the new token
  def self.rotate(id)
    token = new_token
    DB[:devices].where(id:).update(token_sha256: digest(token))
    token
  end

  # true if the device was active
  def self.revoke(id) = DB[:devices].where(id:, revoked_at: nil).update(revoked_at: Time.now) == 1

  # Every token of a kind (revoked ones too), with its vault's name (:vault): the admin panel
  def self.list(kind: 'device') = rows.where(kind:).order(Sequel[:devices][:name]).all

  # After a request: last_seen_at, unless written less than SEEN_EVERY ago (no write per request)
  def self.touch(id, now: Time.now)
    DB[:devices].where(id:).where(Sequel.|({ last_seen_at: nil }, Sequel[:last_seen_at] < now - SEEN_EVERY))
                .update(last_seen_at: now)
  end

  # Devices with their vault's name as :vault
  def self.rows
    DB[:devices].left_join(:vaults, id: :vault_id).select_all(:devices).select_append(Sequel[:vaults][:name].as(:vault))
  end

  def self.check_name(name)
    raise ArgumentError, "bad name #{name.inspect}: [a-z0-9-], at most 64" unless name.to_s.match?(NAME)
  end

  # The row, then what the block adds for its id (returns the Device), in one transaction → [Device, token]
  def self.insert(name, kind, token, vault_id: nil)
    DB.current.transaction do
      id = DB[:devices].insert(name:, kind:, vault_id:, token_sha256: digest(token), created_at: Time.now)
      [yield(id), token]
    end
  end

  def self.new_token = SecureRandom.urlsafe_base64(32, false)
  private_class_method :rows, :check_name, :insert, :new_token
end
