# Names as Vault::NAME / Devices::NAME check them: [a-z0-9-]{1,64}. Times in UTC
Sequel.migration do
  change do
    create_table(:vaults) do
      primary_key :id
      String :name, null: false, unique: true
      DateTime :created_at, null: false
      constraint(:vault_name, Sequel.lit("length(name) BETWEEN 1 AND 64 AND name NOT GLOB '*[^a-z0-9-]*'"))
    end

    # name: the git commit author. A revoked device keeps its row (and its name)
    create_table(:devices) do
      primary_key :id
      String :name, null: false, unique: true
      foreign_key :vault_id, :vaults, null: false
      String :token_sha256, null: false, unique: true
      DateTime :created_at, null: false
      DateTime :revoked_at
      DateTime :last_seen_at
      constraint(:device_name, Sequel.lit("length(name) BETWEEN 1 AND 64 AND name NOT GLOB '*[^a-z0-9-]*'"))
      constraint(:token_sha256, Sequel.lit("length(token_sha256) = 64 AND token_sha256 NOT GLOB '*[^0-9a-f]*'"))
    end
  end
end
