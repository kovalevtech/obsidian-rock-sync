# A code connects one vault (pairings.vault_id: pairing_vaults goes). device_id: a Reconnect code, giving that token a
# new secret instead of making one. expires_at NULL: INIT_VAULT_CODE's, valid until the vault's first device. Codes in
# flight are dropped: they last minutes, the admin issues another
Sequel.migration do
  up do
    drop_table(:pairing_vaults)
    drop_table(:pairings)
    create_table(:pairings) do
      primary_key :id
      String :code, null: false, unique: true
      foreign_key :vault_id, :vaults, null: false
      foreign_key :device_id, :devices, on_delete: :cascade
      DateTime :expires_at
      Integer :wrong, null: false, default: 0
      constraint(:pairing_code, Sequel.lit("length(code) = 6 AND code NOT GLOB '*[^0-9]*'"))
    end
  end
end
