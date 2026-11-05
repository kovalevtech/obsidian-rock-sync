# The SQLite database at Config.database_path: vaults and device tokens. Plain datasets (DB[:devices]), no
# Sequel::Model: no clash with Vault, nothing to load before Zeitwerk. The file is created and migrated on first use;
# its directory must exist (on the server: the /db mount — missing means not mounted, not a fresh install).
module DB
  MIGRATIONS = File.expand_path('../db/migrations', __dir__)
  LOCK = Mutex.new

  Sequel.default_timezone = :utc
  Sequel.extension :migration

  class << self
    def [](table) = current[table]

    # The connection for the current path (tests: one database per test). Found in Sequel's own registry, not kept
    # here: a dev reload of this module doesn't open a second one
    def current
      path = Config.database_path
      LOCK.synchronize { Sequel::DATABASES.find { _1.opts[:database] == path } || connect(path) }
    end

    # Tests: done with this path's database
    def close
      path = Config.database_path
      LOCK.synchronize do
        Sequel::DATABASES.select { _1.opts[:database] == path }.each do |db|
          db.disconnect
          Sequel.synchronize { Sequel::DATABASES.delete(db) }
        end
      end
    end

    private

    def connect(path)
      dir = File.dirname(path)
      raise "database directory missing: #{dir} (not mounted?)" unless Dir.exist?(dir)

      # timeout = busy_timeout (ms); foreign_keys is Sequel's default for SQLite, set anyway. WAL: readers don't wait
      # for a writer. One connection per Puma thread
      db = Sequel.sqlite(path, max_connections: Config.max_threads, timeout: 5000, foreign_keys: true,
                               after_connect: ->(conn) { conn.execute('PRAGMA journal_mode = WAL') })
      Sequel::Migrator.run(db, MIGRATIONS)
      db
    end
  end
end
