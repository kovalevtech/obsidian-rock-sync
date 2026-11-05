# Scoped tokens (the MCP endpoint, mcp_endpoint.rb) next to device tokens: devices.kind. Existing rows are device
# tokens. A scoped token reaches only what its grants name: folders of a vault, each with a mode
Sequel.migration do
  up do
    # SQL: SQLite adds a column with a CHECK in place; Sequel drops add_column's check here, and its add_constraint
    # would rebuild the table, losing the other CHECKs
    run "ALTER TABLE devices ADD COLUMN kind varchar(255) NOT NULL DEFAULT 'device' CHECK (kind IN ('device', 'scoped'))"

    # folder: vault-relative, no slashes around it; '' = the whole vault. One grant per token, vault and folder
    create_table(:grants) do
      primary_key :id
      foreign_key :token_id, :devices, null: false, on_delete: :cascade
      foreign_key :vault_id, :vaults, null: false
      String :folder, null: false
      String :mode, null: false
      unique %i[token_id vault_id folder]
      constraint(:grant_mode, Sequel.lit("mode IN ('r', 'w', 'rw')"))
    end
  end
end
