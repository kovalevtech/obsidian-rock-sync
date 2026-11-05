require 'securerandom'

# One-time codes connecting a device to a vault without copying a token (DB[:pairings]): the admin panel issues one for
# a vault (a new token, named by the device) or for a device token (Reconnect: that token gets a new secret, the device
# reinstalled or lost it); the plugin trades it + a device name for the token (POST /pair). INIT_VAULT_CODE's code
# (EnvInit) has no expiry: it lives until the vault's first device. MAX_WRONG wrong codes in a row burn every active
# one, so guessing gets a few tries per code issued (per boot, for INIT_VAULT_CODE's); the worst it does is make the
# admin issue it again.
module Pairings
  TTL = 10 * 60 # s
  MAX_WRONG = 5
  ATTEMPTS = RateLimit.new(limit: 10, period: 60) # calls of redeem a minute, for everyone: there's no one to tell apart
  LOCK = Mutex.new # a code is read, then used: one process, so no two devices from one code

  # A code for a new device token in the vault → [code, expires_at]. ArgumentError: no such vault
  def self.issue(vault, now: Time.now)
    vault_id = DB[:vaults].where(name: vault.to_s).get(:id) or raise ArgumentError, "no vault #{vault}"
    insert(vault_id:, now:)
  end

  # A code giving an active device token a new secret → [code, expires_at, { name:, vault: }]. ArgumentError: no such
  # token, revoked
  def self.reconnect(device_id, now: Time.now)
    row = DB[:devices].where(id: device_id, kind: 'device', revoked_at: nil).first or raise ArgumentError, 'no such token'
    vault = DB[:vaults].where(id: row[:vault_id]).get(:name)
    [*insert(vault_id: row[:vault_id], device_id:, now:), { name: row[:name], vault: }]
  end

  # INIT_VAULT_CODE, every boot: the code is there, without an expiry, while the vault has no device token (revoked
  # ones count: once used, it's gone for good, a restart doesn't bring it back). code nil: dropped. → :issued | :used | nil
  def self.init(vault, code)
    LOCK.synchronize do
      DB[:pairings].where(expires_at: nil).delete
      next unless code

      vault_id = DB[:vaults].where(name: vault).get(:id)
      next :used unless DB[:devices].where(vault_id:, kind: 'device').empty?

      DB[:pairings].where(code:).delete # an admin's code that happens to be the same
      DB[:pairings].insert(code:, vault_id:)
      :issued
    end
  end

  # → [:paired, device, token] | [:refused] (wrong, used or expired: the same) | [:limited] | [:bad_name, message].
  # The name is only looked at under a good code, and a bad one leaves the code usable. A name other tokens have is
  # fine (it's the commit author, not an identity); a Reconnect code keeps the token's name
  def self.redeem(code, name, now: Time.now)
    return [:limited] unless ATTEMPTS.allow?(:redeem)

    code = code.to_s.gsub(/\s/, '')
    LOCK.synchronize do
      purge(now)
      pairing = DB[:pairings].where(code:).first
      next refuse unless pairing

      result = pairing[:device_id] ? rotate(pairing) : create(pairing, name)
      DB[:pairings].where(id: pairing[:id]).delete
      DB[:pairings].update(wrong: 0)
      result
    rescue ArgumentError => e
      [:bad_name, e.message]
    end
  end

  def self.insert(vault_id:, now:, device_id: nil)
    expires_at = now + TTL
    LOCK.synchronize do
      purge(now)
      code = unused_code
      DB[:pairings].insert(code:, vault_id:, device_id:, expires_at: expires_at.utc)
      [code, expires_at]
    end
  end

  def self.create(pairing, name)
    vault = DB[:vaults].where(id: pairing[:vault_id]).get(:name)
    device, token = Devices.create(name: name.to_s, vault:)
    [:paired, device, token]
  end

  # Revoked since the code was issued: nothing to give a secret to (the device row stays, so the cascade didn't run)
  def self.rotate(pairing)
    device_id = pairing[:device_id]
    return [:refused] unless DB[:devices].where(id: device_id, revoked_at: nil).count == 1

    token = Devices.rotate(device_id)
    [:paired, Devices.authenticate(token).first, token]
  end

  def self.unused_code
    loop do
      code = format('%06d', SecureRandom.random_number(1_000_000))
      return code if DB[:pairings].where(code:).empty?
    end
  end

  # expires_at is stored in UTC: compared as text, and an offset would change with the clocks. NULL (INIT_VAULT_CODE's)
  # never matches
  def self.purge(now) = DB[:pairings].where(Sequel[:expires_at] <= now.utc).delete

  # Counted on the active codes: with none there's nothing to guess, and nothing to burn the next one
  def self.refuse
    DB[:pairings].update(wrong: Sequel[:wrong] + 1)
    DB[:pairings].delete unless DB[:pairings].where(Sequel[:wrong] >= MAX_WRONG).empty?
    [:refused]
  end
  private_class_method :insert, :create, :rotate, :unused_code, :purge, :refuse
end
