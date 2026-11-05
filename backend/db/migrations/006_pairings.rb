# One-time codes connecting a device (Pairings): a row lives until its code is used, expired or burned. The code in the
# clear: a hash of 6 digits would hide nothing. wrong: wrong codes in a row since it was issued
Sequel.migration do
  change do
    create_table(:pairings) do
      primary_key :id
      String :code, null: false, unique: true
      DateTime :expires_at, null: false
      Integer :wrong, null: false, default: 0
      constraint(:pairing_code, Sequel.lit("length(code) = 6 AND code NOT GLOB '*[^0-9]*'"))
    end
    create_table(:pairing_vaults) do
      foreign_key :pairing_id, :pairings, null: false, on_delete: :cascade
      foreign_key :vault_id, :vaults, null: false
      primary_key %i[pairing_id vault_id]
    end
  end
end
