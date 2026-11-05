# A token's name is the commit author, not an identity: several tokens may share one (a phone in two vaults, a
# device connected again). devices loses UNIQUE on name. Rebuilt by hand in SQL (Sequel's rebuild drops the CHECKs),
# with foreign keys off: dropping the old table would otherwise cascade into scoped_token_grants and pairings. Their
# references name `devices`, so after the rename they point at the new table. The pragma can't change inside a
# transaction: no_transaction, then one of our own on the same connection
Sequel.migration do
  no_transaction

  up do
    synchronize do
      run 'PRAGMA foreign_keys = OFF'
      transaction do
        run <<~SQL
          CREATE TABLE devices_new (
            id integer NOT NULL PRIMARY KEY AUTOINCREMENT,
            name varchar(255) NOT NULL,
            token_sha256 varchar(255) NOT NULL UNIQUE,
            created_at timestamp NOT NULL,
            revoked_at timestamp,
            last_seen_at timestamp,
            kind varchar(255) NOT NULL DEFAULT 'device' CHECK (kind IN ('device', 'scoped')),
            vault_id integer REFERENCES vaults(id),
            CONSTRAINT device_name CHECK (length(name) BETWEEN 1 AND 64 AND name NOT GLOB '*[^a-z0-9-]*'),
            CONSTRAINT token_sha256 CHECK (length(token_sha256) = 64 AND token_sha256 NOT GLOB '*[^0-9a-f]*')
          )
        SQL
        columns = 'id, name, token_sha256, created_at, revoked_at, last_seen_at, kind, vault_id'
        run "INSERT INTO devices_new (#{columns}) SELECT #{columns} FROM devices"
        run 'DROP TABLE devices'
        run 'ALTER TABLE devices_new RENAME TO devices'
        raise 'foreign keys broken' unless fetch('PRAGMA foreign_key_check').all.empty?
      end
    ensure
      run 'PRAGMA foreign_keys = ON'
    end
  end
end
