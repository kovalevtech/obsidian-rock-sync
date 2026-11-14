# The admin's vault history (History): an index of every vault's git history, a cache — deleting its rows is always
# safe, the next page load rebuilds them, nothing else reads them. history_events: one row per path a commit changed
# (git log --raw -M), in history order (seq). history_entries: those events grouped as the page shows them (an edit
# run, a deletion, a folder burst …), its id = its first event's. history_state: how far a vault is indexed
Sequel.migration do
  change do
    create_table(:history_state) do
      foreign_key :vault_id, :vaults, null: false, on_delete: :cascade
      primary_key [:vault_id]
      String :head, null: false # the last commit indexed
      Integer :seq, null: false # its seq
    end

    create_table(:history_events) do
      primary_key :id
      foreign_key :vault_id, :vaults, null: false, on_delete: :cascade
      Integer :seq, null: false # the commit's place in history: 1 = the root, along first parents
      String :sha, null: false # the commit
      Integer :at, null: false # its time, unix seconds
      String :author_kind, null: false # Vault::Author.of: device / token / unknown
      String :author_name, null: false
      String :action, null: false # added / modified / deleted / renamed
      String :path, null: false # renamed: the new path
      String :old_path # renamed: the old one
      String :blob_before # the version it replaced (deleted: the one deleted)
      String :blob_after # the version it left (deleted: nil)
      Integer :size # bytes of blob_after (deleted: of blob_before)
      Integer :entry_id # the entry shown for it; nil: none (hidden paths, a .keep outside a folder entry)
      index %i[vault_id seq path], unique: true
      index %i[vault_id path seq]
      index :entry_id
    end

    create_table(:history_entries) do
      Integer :id, primary_key: true # its first event's id: stable while later commits extend it
      foreign_key :vault_id, :vaults, null: false, on_delete: :cascade
      String :kind, null: false # created / edited / deleted / renamed / folder_deleted / folder_renamed
      String :path, null: false # a file's path (renamed: the new one), a folder's (folder_*)
      String :old_path # renamed / folder_renamed: from
      String :author_kind, null: false
      String :author_name, null: false
      String :author_key, null: false # the name, downcased (filters)
      String :search, null: false # its paths downcased, a folder's files too, one a line (filters)
      Integer :first_at, null: false
      Integer :last_at, null: false
      Integer :first_seq, null: false
      Integer :last_seq, null: false
      Integer :versions, null: false # commits in it
      Integer :files # folder_*: files moved / deleted with the folder
      String :blob_before # the version before the entry
      String :blob_after # the version it ends with
      Integer :size
      index %i[vault_id last_at id]
      index %i[vault_id kind last_at]
    end
  end
end
