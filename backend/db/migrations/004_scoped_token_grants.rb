# Grants: any number of folders in any number of vaults per scoped token (003 kept one vault per token, in code only).
# The table keeps its rows and constraints under the new name
Sequel.migration do
  up do
    rename_table :grants, :scoped_token_grants
  end

  down do
    rename_table :scoped_token_grants, :grants
  end
end
