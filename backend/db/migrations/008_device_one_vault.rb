# A device token has one vault (devices.vault_id; device_vaults goes). Tokens with one carry on as they were; tokens
# with several (from before connection codes) or none are deleted, with their pending Reconnect codes: their devices
# connect again with a code. Plain SQL for the column: Sequel's add_column on SQLite may rebuild the table and drop its
# CHECK constraints
Sequel.migration do
  up do
    run 'ALTER TABLE devices ADD COLUMN vault_id integer REFERENCES vaults(id)'
    from(:devices).where(kind: 'device')
                  .update(vault_id: from(:device_vaults).where(device_id: Sequel[:devices][:id]).select(:vault_id).limit(1))
    several = from(:device_vaults).group(:device_id).having { count.function.* > 1 }.select(:device_id)
    gone = from(:devices).where(kind: 'device').where(Sequel.|({ id: several }, { vault_id: nil })).select_map(:id)
    from(:pairings).where(device_id: gone).delete
    from(:device_vaults).where(device_id: gone).delete
    from(:devices).where(id: gone).delete
    drop_table(:device_vaults)
  end
end
