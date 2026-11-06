require 'digest'
require 'open3'
require 'tmpdir'

# Thin wrapper around the git CLI: one repository used as a content store — blobs, trees, commits, its index — never
# through a work tree; only the commands we use. Knows nothing about what's stored in it, nor where the files are kept
# as plain files (the vault's tree/ is the vault's business): nothing there — .gitignore, .gitattributes, a nested
# .git — changes what git does.
class Git
  class Error < StandardError; end

  # The user's own git config stays out (commit signing, hooks, merge styles): same behaviour on every machine. Paths
  # are literal everywhere: no pathspec magic (`:/x`, `:(exclude)x`, `*.md` are names)
  ENV_ISOLATED = { 'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_LITERAL_PATHSPECS' => '1' }.freeze
  # New paths in the index: .git look-alikes refused whatever the platform's default (HFS+ / NTFS spellings). HEAD
  # read into it as it is (read-tree checks paths too): a vault holding one from before must not stop taking writes
  PROTECT_PATHS = %w[-c core.protectHFS=true -c core.protectNTFS=true].freeze
  TAKE_PATHS = %w[-c core.protectHFS=false -c core.protectNTFS=false].freeze
  NO_SHA = '0' * 40

  attr_reader :git_dir

  # user: [name, email] for commits. tmp_dir: where merge_file puts its temp files (keep content where the repo is)
  def initialize(git_dir:, user: %w[git git@localhost], tmp_dir: Dir.tmpdir)
    @git_dir = git_dir
    @user = user
    @tmp_dir = tmp_dir
  end

  # Same hash git uses for blobs: matches `git hash-object` and `git ls-tree`
  def self.blob_hash(content)
    Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
  end

  def exist?
    Dir.exist?(git_dir)
  end

  # Without --work-tree: git would store it in the repo's config as an absolute core.worktree, and commands naming only
  # the git dir would fail once VAULTS_DIR is mounted elsewhere (a container, a restore)
  def init(branch: 'main')
    out, status = Open3.capture2e(ENV_ISOLATED, 'git', "--git-dir=#{git_dir}", 'init', '-q', '-b', branch,
                                  chdir: File.dirname(git_dir))
    raise Error, "git init failed: #{out}" unless status.success?
  end

  # One commit on top of HEAD; returns its hash. changes: { path => blob hash (hash_object) | nil (removed) }.
  # Plumbing only (read-tree, update-index, write-tree, commit-tree, update-ref): nothing is read from a work tree, so
  # no ignore rules, attributes, filters, hooks or nested repos — git stores exactly the blobs it's given. The index is
  # reset to HEAD first: what a failed attempt left in it never slips into a commit, and it stays equal to HEAD (a
  # cleanup by hand can use it). author: [name, email]; nil = the committer (user)
  def commit(message, changes, author: nil)
    parent = run('rev-parse', '-q', '--verify', 'HEAD^{commit}', allow_failure: true).chomp
    parent = nil if parent.empty?
    run(*(parent ? ['read-tree', parent] : %w[read-tree --empty]), config: TAKE_PATHS)
    # Mode 0 = remove. update-index checks each path: no .git, nor its look-alikes (PROTECT_PATHS)
    entries = changes.map { |path, sha| "#{sha ? "100644 #{sha}" : "0 #{NO_SHA}"}\t#{path}\0" }.join
    run('update-index', '-z', '--add', '--index-info', stdin: entries, config: PROTECT_PATHS)
    tree = run('write-tree').chomp
    env = author ? { 'GIT_AUTHOR_NAME' => author[0], 'GIT_AUTHOR_EMAIL' => author[1] } : {}
    commit = run('commit-tree', tree, *(parent ? ['-p', parent] : []), stdin: "#{message}\n", env:).chomp
    # Only from the parent read above (the vault lock keeps others out; if anything moved HEAD meanwhile, this fails)
    run('update-ref', 'HEAD', commit, parent || NO_SHA)
    commit
  end

  # Stores content as a blob; returns its hash. From stdin, without --path: no filters, the bytes as given
  def hash_object(content)
    run('hash-object', '-w', '--stdin', stdin: content).chomp
  end

  # Blob content by hash; nil if git doesn't have it (never stored, or gc'd)
  def cat_file(hash)
    return nil unless hash.to_s.match?(/\A\h{40}\z/)

    out, _err, status = Open3.capture3(ENV_ISOLATED, *command, 'cat-file', 'blob', hash, binmode: true, chdir: git_dir)
    status.success? ? out : nil
  end

  # { path => [blob hash, size in bytes] } of a commit, recursively
  def ls_tree(rev)
    # -z: raw paths (no quoting of spaces / non-ASCII), NUL-separated. -l: with the blob's size
    run('ls-tree', '-r', '-l', '-z', rev).split("\0").to_h do |entry|
      meta, path = entry.split("\t", 2) # "<mode> blob <sha> <size, padded>\t<path>"
      _mode, _type, sha, size = meta.split
      [path, [sha, size.to_i]]
    end
  end

  # Latest commit on any branch; nil before the first commit
  def head
    sha = run('rev-list', '-n1', '--all').chomp
    sha.empty? ? nil : sha
  end

  # Time of the last commit touching path; nil if never committed
  def last_commit_time(path)
    time = run('log', '-1', '--format=%ct', '--', path).strip
    time.empty? ? nil : Time.at(time.to_i)
  end

  # The last commit touching each of paths, in one walk back through history (not a `log -1` per file), stopped once
  # all are found: { path => { time:, name:, email:, client: } } (client: the `Client:` trailer); paths never committed
  # are left out. under: the folder to walk ('' = everything)
  def last_commits(paths, under: '')
    wanted = paths.to_set
    found = {}
    return found if wanted.empty?

    # -z: raw paths, NUL after each. A commit = RS, its fields split by US, NUL, "\n", then its paths
    format = '%x1e%ct%x1f%an%x1f%ae%x1f%(trailers:key=Client,valueonly,separator=%x2C)'
    log = [*command, 'log', '-z', "--format=#{format}", '--name-only', *(under.empty? ? [] : ['--', under])]
    IO.popen(ENV_ISOLATED, log, 'rb', chdir: git_dir, err: File::NULL) do |io|
      io.each_line("\x1e") do |record|
        header, *names = record.chomp("\x1e").force_encoding(Encoding::UTF_8).split("\0")
        next unless header

        time, name, email, client = header.split("\x1f", -1)
        names.each do |path|
          path = path.delete_prefix("\n")
          next if found.key?(path) || !wanted.include?(path)

          found[path] = { time: Time.at(time.to_i).utc, name:, email:, client: client.to_s.empty? ? nil : client }
        end
        break if found.size == wanted.size
      end
    end
    found
  end

  # 3-way merge of contents (not paths): [text, number of conflicts], or nil if git can't (binary files).
  # labels: [current, base, other] for the conflict markers. conflictStyle pinned: a global diff3 / zdiff3 setting
  # would add a base section (kept although the global config is out: the repo's own config could set it). Temp files
  # outside any work tree, named by us: no attributes (merge drivers, eol) apply; --git-dir: no repo looked for around
  # the server's working directory
  def merge_file(current, base, other, labels:, marker_size: 7)
    Dir.mktmpdir('merge-', @tmp_dir) do |dir|
      files = { current:, base:, other: }.map do |name, data|
        File.join(dir, name.to_s).tap { |f| File.binwrite(f, data) }
      end
      out, _err, status = Open3.capture3( # err: "Cannot merge binary files" — an outcome, not an error
        ENV_ISOLATED, *command, '-c', 'merge.conflictStyle=merge', 'merge-file', '-p', "--marker-size=#{marker_size}",
        *labels.flat_map { ['-L', _1] }, *files,
        binmode: true, chdir: dir
      )
      # exit status = number of conflicts (capped at 127), >127 on error (binary files included)
      next nil if status.exitstatus.nil? || status.exitstatus > 127

      [out, status.exitstatus]
    end
  end

  # Packs loose objects (versions stored as deltas), prunes unreachable ones older than git's grace period (2 weeks):
  # reachable ones — every committed version — always stay. Safe next to commits and reads (git's own guarantee).
  # Files over 50 MB are packed whole: a delta search over big media costs time and memory for nothing
  def gc
    run('gc', '--quiet', env: { 'GIT_CONFIG_COUNT' => '1', 'GIT_CONFIG_KEY_0' => 'core.bigFileThreshold',
                                'GIT_CONFIG_VALUE_0' => '50m' })
  end

  # { loose:, packs: } object counts
  def count_objects
    stats = run('count-objects', '-v').lines.to_h { |line| line.chomp.split(': ', 2) }
    { loose: stats['count'].to_i, packs: stats['packs'].to_i }
  end

  private

  # stdin: data for the command (binary). config: `-c` options for this one. allow_failure: its output whatever the
  # exit status
  def run(*args, env: {}, stdin: '', config: [], allow_failure: false)
    out, err, status = Open3.capture3(ENV_ISOLATED.merge(env), *command, *config, *args, stdin_data: stdin,
                                                                                         binmode: true, chdir: git_dir)
    raise Error, "git #{args.first} failed: #{err}" unless status.success? || allow_failure

    out.force_encoding(Encoding::UTF_8) # paths, hashes, numbers (binary in: stdin only)
  end

  # The work tree is the git dir itself (it overrides a core.worktree from before, too): whatever a command might look
  # for in a work tree (.gitattributes, .gitignore, a .git) is never the vault's
  def command
    ['git', "--git-dir=#{git_dir}", "--work-tree=#{git_dir}", '-c', "user.name=#{@user[0]}", '-c', "user.email=#{@user[1]}"]
  end
end
