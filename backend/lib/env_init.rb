# A first run from the environment (Config.init; config.ru, after Vault.check!: a vault whose repo is missing stops
# the boot before anything here). Every boot, so it only makes what's missing and otherwise leaves things alone: what
# the admin panel did to the vault stands. INIT_VAULT_CODE connects the vault's first device without the admin panel:
# valid until a device token for the vault exists, then never again (Pairings.init).
module EnvInit
  def self.call(init)
    vault(init.vault) if init
    case Pairings.init(init&.vault, init&.code)
    when :issued then log "INIT_VAULT_CODE: open for the first device of #{init.vault}"
    when :used then log "INIT_VAULT_CODE: ignored, #{init.vault} has its devices already"
    end
  end

  def self.vault(name)
    return if Vault.names.include?(name)

    Vault.create(name)
    log "vault #{name} created"
  end

  def self.log(line) = puts("vault-sync: #{line}")
  private_class_method :vault, :log
end
