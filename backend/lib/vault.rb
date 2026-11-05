require 'fileutils'
require 'monitor'

# One vault on disk: VAULTS_DIR/<name>/tree (current files, plain) + VAULTS_DIR/<name>/repo.git (history, kept outside the
# tree), with its own lock and change feed. Every change is one commit. A vault exists when its row (DB[:vaults]) and
# its repo both do: the list comes from the database, never from VAULTS_DIR. Only Vault.create (admin panel,
# `make vault`, EnvInit) makes one; Vault.find never does: a missing vault is an error, not a write somewhere.
class Vault
  NAME = /\A[a-z0-9-]{1,64}\z/
  INSTANCES = Mutex.new
  @instances = {}

  # The vault, or nil (bad name, no row, no repo). One instance per vault: requests share its lock and feed
  def self.find(name)
    return unless name.is_a?(String) && name.match?(NAME)
    return if DB[:vaults].where(name:).empty?

    dir = dir_of(name)
    return unless Dir.exist?(File.join(dir, 'repo.git'))

    INSTANCES.synchronize { @instances[dir] ||= new(name, dir) }
  end

  # Tree + empty repo (an existing one is kept), then the row. ArgumentError: bad name, name taken, VAULTS_DIR missing
  # (not created: it's a mount — a repo written to the mount point would land outside the storage)
  def self.create(name)
    raise ArgumentError, "bad vault name #{name.inspect}: [a-z0-9-], at most 64" unless name.to_s.match?(NAME)
    raise ArgumentError, "vault #{name} exists" unless DB[:vaults].where(name:).empty?
    raise ArgumentError, "vaults directory missing: #{Config.vaults_dir}" unless Dir.exist?(Config.vaults_dir)

    new(name, dir_of(name)).setup!
    DB[:vaults].insert(name:, created_at: Time.now)
    find(name)
  rescue Sequel::UniqueConstraintViolation
    raise ArgumentError, "vault #{name} exists"
  end

  # Names, from the database
  def self.names = DB[:vaults].order(:name).select_map(:name)

  # Boot: VAULTS_DIR exists, and every vault in the database has its repo there. On the server a miss means VAULTS_DIR
  # isn't mounted — not a vault to recreate
  def self.check!
    dir = File.expand_path(Config.vaults_dir)
    raise "vaults directory missing: #{dir} (not mounted?)" unless Dir.exist?(dir)

    names.each do |name|
      repo = File.join(dir_of(name), 'repo.git')
      raise "vault #{name} missing: no #{repo}" unless Dir.exist?(repo)
    end
  end

  def self.dir_of(name) = File.expand_path(name, Config.vaults_dir)

  attr_reader :name, :tree, :git, :feed

  def initialize(name, dir)
    @name = name
    @tree = File.join(dir, 'tree')
    # Temp files of merges next to the data: vault content stays on its storage
    @git = Git.new(git_dir: File.join(dir, 'repo.git'), work_tree: @tree, user: %w[sync sync@localhost], tmp_dir: dir)
    # The git index is not safe for concurrent writes; readers take it too, not to see a half-written file.
    # Reentrant (Monitor): WriteFile holds it while MergeVersions takes it again
    @lock = Monitor.new
    @feed = ChangeFeed.new
    @compaction_lock = Mutex.new
  end

  def setup!
    FileUtils.mkdir_p(tree)
    git.init unless git.exist?
    self
  end

  def lock(&) = @lock.synchronize(&)

  # Relative path inside the tree (Vault::Path::BadPath if it escapes)
  def normalize(path) = Path.normalize(path, tree)

  # Absolute path in the tree of a normalized (relative) path
  def file(rel) = File.join(tree, rel)

  # Every write is its own commit (no amend): any version a client synced stays a base for 3-way merges.
  # author: Vault::Author (git author + `Client:` trailer); nil = the server. Long polls hear about it
  def commit(message, author: nil)
    message = "#{message}\n\nClient: #{author.client}" if author&.client
    git.commit(message, author: author && [author.name, author.email])
    feed.notify
  end

  # HEAD sha: the manifest's version (nil before the first commit). No lock: a read, and ChangeFeed#wait calls it
  # while holding its own lock
  def version = git.head

  # Bytes (admin panel): files = the current version (HEAD's blobs, as the manifest lists them), history = repo.git on
  # disk (its regular files: every version, packed or not), total = both. A file git drops meanwhile (gc) counts as 0
  def sizes
    files = version ? git.ls_tree(version).sum { |_, (_, size)| size } : 0
    history = Dir.glob('**/*', File::FNM_DOTMATCH, base: git.git_dir).sum do |rel|
      stat = File.lstat(File.join(git.git_dir, rel)) rescue nil
      stat&.file? ? stat.size : 0
    end
    { files:, history:, total: files + history }
  end

  # Admin (grants): the folders of the current version, hidden ones left out
  def folders
    paths = version ? git.ls_tree(version).keys : []
    dirs = paths.flat_map { |path| (parts = path.split('/')[0...-1]).each_index.map { parts[.._1].join('/') } }
    dirs.uniq.reject { Access.hidden?(_1) }.sort
  end

  # Admin: git gc in a thread of its own (a big vault takes a while; no lock — git copes with commits meanwhile). One at
  # a time; the last run, in memory: { started_at, finished_at, before, after, error }. Returns the thread (tests
  # wait on it), nil if one is running
  def compact
    @compaction_lock.synchronize do
      return if compacting?

      @compaction = { started_at: Time.now, before: sizes[:history] }
      @compaction_thread = Thread.new do
        git.gc
        @compaction[:after] = sizes[:history]
      rescue StandardError => e
        @compaction[:error] = e.message
        warn "vault-sync: compacting #{name} failed: #{e.message}"
      ensure
        @compaction[:finished_at] = Time.now
      end
    end
  end

  def compacting? = @compaction_thread&.alive? || false

  attr_reader :compaction

  # Directories left empty by a delete / move go too: git doesn't track them, the tree mirrors git
  def prune_dirs(dir)
    while dir != tree && Dir.exist?(dir) && Dir.empty?(dir)
      Dir.rmdir(dir)
      dir = File.dirname(dir)
    end
  end
end
