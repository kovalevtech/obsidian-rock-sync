# A device may use several vaults: devices.vault_id → device_vaults (one row per device and vault). devices is rebuilt
# by hand: Sequel's own table rebuild (drop_column on SQLite) drops the CHECK constraints. device_vaults refers to the
# new table, so dropping the old one cascades nothing; the rename updates that reference
Sequel.migration do
  up do
    create_table(:devices_new) do
      primary_key :id
      String :name, null: false, unique: true
      String :token_sha256, null: false, unique: true
      DateTime :created_at, null: false
      DateTime :revoked_at
      DateTime :last_seen_at
      constraint(:device_name, Sequel.lit("length(name) BETWEEN 1 AND 64 AND name NOT GLOB '*[^a-z0-9-]*'"))
      constraint(:token_sha256, Sequel.lit("length(token_sha256) = 64 AND token_sha256 NOT GLOB '*[^0-9a-f]*'"))
    end
    columns = %i[id name token_sha256 created_at revoked_at last_seen_at]
    self[:devices_new].import(columns, self[:devices].select(*columns))

    create_table(:device_vaults) do
      foreign_key :device_id, :devices_new, null: false, on_delete: :cascade
      foreign_key :vault_id, :vaults, null: false
      primary_key %i[device_id vault_id]
    end
    self[:device_vaults].import(%i[device_id vault_id], self[:devices].select(:id, :vault_id))

    drop_table(:devices)
    rename_table(:devices_new, :devices)
  end
end
