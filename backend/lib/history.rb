# The admin's vault history: an index of each vault's git history in the database (migration 011), caught up when the
# history page is opened — `git log <last indexed>..HEAD`, only new commits (Vault#commit knows nothing of it). A cache:
# its rows may be deleted at any time, the next catch-up rebuilds them; HEAD no longer a descendant of the last indexed
# commit (history rewritten) → the vault's rows dropped and rebuilt. Events come from git's own diff of each commit
# (Git#each_commit), never from the message: adopted repos and early commits change many files at once.
#
# Entries (History::Grouping) are stored too. A catch-up regroups only the tail: entries a new commit could still
# extend — those ending less than WINDOW before the first new commit, and further back over a chain of deletions /
# renames less than BURST_GAP apart (a folder burst cut by the catch-up). Entries ending earlier can't change: the same
# result as a rebuild.
#
# Catch-ups take a lock (FileLock next to the database: across processes); events are unique per vault, commit and
# path besides. More than SYNC_LIMIT commits to index → a thread of its own (the page says "indexing…"), like Compact.
module History
  SYNC_LIMIT = 100_000 # commits a page load indexes itself (50k took 1.3 s on a laptop)
  BATCH = 5000 # events per transaction (a full build doesn't hold SQLite's write lock for long)
  PAGE = 50
  THREADS = Mutex.new
  @threads = {}
  @locks = {}

  class << self
    # Brings the vault's index up to HEAD: :current, or :indexing (a thread of its own does it; also while one runs)
    def catch_up(vault)
      THREADS.synchronize do
        return :indexing if @threads[vault.name]&.alive?

        if pending(vault) > sync_limit
          @threads[vault.name] = Thread.new do
            index!(vault)
          rescue StandardError => e
            warn "vault-sync: indexing the history of #{vault.name} failed: #{e.class}: #{e.message}"
          end
          return :indexing
        end
      end
      index!(vault)
      :current
    end

    # Tests: another limit (nil: SYNC_LIMIT)
    attr_writer :sync_limit

    def sync_limit = @sync_limit || SYNC_LIMIT

    # The background build's thread (tests wait on it)
    def thread(vault) = THREADS.synchronize { @threads[vault.name] }

    # Commits not indexed yet (all of them if the index is stale)
    def pending(vault)
      head = vault.version or return 0
      state = DB[:history_state][vault_id: vault_id(vault)]
      return 0 if state && state[:head] == head
      return vault.git.count(head, since: state[:head]) if state && vault.git.ancestor?(state[:head], head)

      vault.git.count(head)
    end

    # Indexes what's new, under the lock: a second caller finds it done
    def index!(vault)
      lock.synchronize do
        id = vault_id(vault)
        head = vault.version
        state = DB[:history_state][vault_id: id]
        next if state&.dig(:head) == head

        state = nil if state && !(head && vault.git.ancestor?(state[:head], head))
        seq = state ? state[:seq] : 0
        # Rows of an interrupted run (state is written last), or all of them for a rebuild
        DB.current.transaction do
          DB[:history_entries].where(vault_id: id).delete unless state
          DB[:history_events].where(vault_id: id).where { Sequel[:seq] > seq }.delete
          DB[:history_state].where(vault_id: id).delete unless state
        end
        next unless head

        last = insert_events(vault, id, head, state&.dig(:head), seq)
        regroup(id, seq, state ? cut(id, seq) : nil, head, last)
      end
    end

    # Entries of a tab (:all, :deleted, :moves), newest first. filters: author / path (substrings, any case), since /
    # till (Time). before: the last entry of the page before ([last_at, id]). Returns [entries, more?]
    def entries(vault, tab: :all, author: nil, path: nil, since: nil, till: nil, before: nil, limit: PAGE)
      ds = DB[:history_entries].where(vault_id: vault_id(vault))
      ds = case tab
           when :deleted then deleted(ds)
           when :moves then ds.where(kind: %w[renamed folder_renamed])
           else ds
           end
      ds = ds.where(Sequel.like(:author_key, "%#{ds.escape_like(author.downcase)}%")) if author && !author.empty?
      ds = ds.where(Sequel.like(:search, "%#{ds.escape_like(path.downcase)}%")) if path && !path.empty?
      ds = ds.where { last_at >= since.to_i } if since
      ds = ds.where { first_at < till.to_i } if till
      if before
        at, id = before
        ds = ds.where(Sequel.lit('last_at < ? OR (last_at = ? AND id < ?)', at, at, id))
      end
      rows = ds.order(Sequel.desc(:last_at), Sequel.desc(:id)).limit(limit + 1).all
      [rows.first(limit), rows.size > limit]
    end

    def entry(vault, id) = DB[:history_entries][vault_id: vault_id(vault), id: id.to_i]

    # Its events, oldest first
    def events(entry) = DB[:history_events].where(entry_id: entry[:id]).order(:seq, :id).all

    # Distinct author names, for the filter's suggestions
    def authors(vault) = DB[:history_entries].where(vault_id: vault_id(vault)).distinct.order(:author_name).select_map(:author_name)

    # A path's newest event with this blob in the vault (the admin's blob route: only what the index knows), or nil
    def blob_event(vault, sha)
      # Shown paths only: a hidden one's events belong to no entry
      DB[:history_events].where(vault_id: vault_id(vault)).exclude(entry_id: nil)
                         .where(Sequel.|({ blob_after: sha }, { blob_before: sha })).reverse(:seq).first
    end

    # Was the path (a deleted file / folder's .keep) written again after the entry?
    def back?(entry, path) = DB[:history_events].where(vault_id: entry[:vault_id], path:).where { seq > entry[:last_seq] }.any?

    private

    def lock
      path = "#{Config.database_path}.history.lock"
      THREADS.synchronize { @locks[path] ||= FileLock.new(path) }
    end

    def vault_id(vault) = DB[:vaults].where(name: vault.name).get(:id)

    # Deleted now: no event at its path (a folder's .keep) after the deletion
    def deleted(ds)
      later = DB[:history_events].where(vault_id: Sequel[:history_entries][:vault_id])
                                 .where(path: Sequel.case({ 'folder_deleted' => Sequel.join([Sequel[:history_entries][:path], '/.keep']) },
                                                          Sequel[:history_entries][:path], Sequel[:history_entries][:kind]))
                                 .where { Sequel[:history_events][:seq] > Sequel[:history_entries][:last_seq] }
      ds.where(kind: %w[deleted folder_deleted]).exclude(later.exists)
    end

    # Events of the commits after `since`, numbered on from seq, in batches; returns the last seq
    def insert_events(vault, id, head, since, seq)
      batch = []
      flush = lambda do
        sizes = vault.git.blob_sizes(batch.flat_map { [_1[:blob_after] || _1[:blob_before]] }.uniq)
        batch.each { _1[:size] = sizes[_1[:blob_after] || _1[:blob_before]] }
        DB[:history_events].multi_insert(batch)
        batch.clear
      end
      vault.git.each_commit(head, since:) do |commit|
        seq += 1
        author = Vault::Author.of(name: commit[:name], email: commit[:email], client: commit[:client])
        commit[:changes].each do |change|
          batch << { vault_id: id, seq:, sha: commit[:sha], at: commit[:time], author_kind: author[:kind],
                     author_name: author[:name].to_s.scrub, action: change[:action].to_s, path: change[:path].scrub,
                     old_path: change[:old_path]&.scrub, blob_before: change[:before], blob_after: change[:after] }
        end
        flush.call if batch.size >= BATCH
      end
      flush.call if batch.any?
      seq
    end

    # Where the tail starts (an epoch time): WINDOW before the first new event, and further back over deletions /
    # renames chained less than BURST_GAP apart
    def cut(id, seq)
      first = DB[:history_events].where(vault_id: id).where { Sequel[:seq] > seq }.min(:at) or return nil
      cut = first - Grouping::WINDOW
      DB[:history_events].where(vault_id: id, action: %w[deleted renamed]).where { at < cut }.reverse(:at)
                         .select(:at).each do |row|
        break if cut - row[:at] >= Grouping::BURST_GAP

        cut = row[:at]
      end
      cut
    end

    # Regroups the tail (cut nil: everything) with the new events and stores the result with the new state, at once
    def regroup(id, seq, cut, head, last)
      events = DB[:history_events].where(vault_id: id)
      tail = cut ? DB[:history_entries].where(vault_id: id).where { last_at >= cut }.select_map(:id) : nil
      if cut
        events = events.where(Sequel.|({ entry_id: tail }, Sequel.&({ entry_id: nil }, Sequel[:at] >= cut),
                                       Sequel[:seq] > seq))
      end
      events = events.order(:seq, :id).all
      entries = Grouping.call(events)
      DB.current.transaction do
        DB[:history_entries].where(vault_id: id, id: tail).delete if tail
        DB[:history_entries].multi_insert(entries.map { _1.except(:members).merge(vault_id: id) })
        DB.current.run('CREATE TEMP TABLE IF NOT EXISTS history_members (event_id INTEGER PRIMARY KEY, entry_id INTEGER)')
        DB.current.run('DELETE FROM history_members')
        DB[:history_members].import(%i[event_id entry_id], entries.flat_map { |e| e[:members].map { [_1, e[:id]] } })
        DB[:history_events].where(id: events.map { _1[:id] })
                           .update(entry_id: DB[:history_members].where(event_id: Sequel[:history_events][:id]).select(:entry_id))
        DB[:history_state].insert_conflict(:replace).insert(vault_id: id, head:, seq: last)
      end
    end
  end
end
