# A grant's purpose: what the folder is for and how to use it, in the admin's words; MCP tells it to Claude
Sequel.migration do
  change do
    add_column :scoped_token_grants, :purpose, String, text: true, null: false, default: ''
  end
end
