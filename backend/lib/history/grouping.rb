module History
  # Events (history_events rows, oldest first) → the entries the history page shows, each with its events' ids
  # (:members). Pure: no database, no git.
  #
  # - An edit run: one file, one author, each commit less than WINDOW after the previous one (a sliding window, no cap
  #   on the whole). Commits to other files in between don't break it; one by another author to the same file does.
  #   Edits, merges and appends alike (git sees modifications). Starting with a creation: `created`, else `edited`.
  # - A deletion or a rename is an entry of its own and ends the file's run (both paths' for a rename).
  # - A folder burst: what the plugin sends for a folder deleted / renamed in Obsidian — one commit per file and one for
  #   the folder's .keep. The deletions (renames) of one author, each less than BURST_GAP after that author's previous
  #   one, form a run; every folder whose .keep is deleted (renamed F → G) in it takes the run's deletions under F/
  #   (renames F/x → G/x), its subfolders' included: one `folder_deleted` / `folder_renamed` entry. Nested folders go
  #   into the outermost one.
  # - Hidden paths (any dot segment) never show; a .keep only as part of a folder entry.
  module Grouping
    WINDOW = 15 * 60 # s
    BURST_GAP = 60 # s

    module_function

    def call(events)
      runs = {} # path → the run it may extend
      entries = []
      keeps = [] # .keep deletions / renames: folder bursts
      events.each do |e|
        case role(e)
        when :keep then keeps << e if e[:action] == 'deleted' || (e[:action] == 'renamed' && role_of(e[:old_path]) == :keep)
        when :file then file_event(e, runs, entries)
        end
      end
      folders(entries, keeps)
    end

    # :file, :keep (a visible folder's), :hidden
    def role(e) = role_of(e[:path])

    def role_of(path)
      parts = path.to_s.split('/')
      return :keep if parts.size > 1 && parts.last == '.keep' && parts[0...-1].none? { _1.start_with?('.') }

      parts.any? { _1.start_with?('.') } ? :hidden : :file
    end

    def file_event(e, runs, entries)
      case e[:action]
      when 'added', 'modified'
        run = runs[e[:path]]
        if run && same_author?(run, e) && e[:at] - run[:last_at] < WINDOW
          extend_entry(run, e)
        else
          runs[e[:path]] = entry(e, e[:action] == 'added' ? 'created' : 'edited').tap { entries << _1 }
        end
      when 'deleted'
        runs.delete(e[:path])
        entries << entry(e, 'deleted')
      when 'renamed'
        runs.delete(e[:path])
        runs.delete(e[:old_path])
        # Out of a hidden path: it appears; into one: covered by role (hidden → nothing)
        entries << entry(e, role_of(e[:old_path]) == :file ? 'renamed' : 'created')
      end
    end

    def same_author?(a, b) = a[:author_kind] == b[:author_kind] && a[:author_name] == b[:author_name]

    def entry(e, kind)
      { id: e[:id], kind:, path: e[:path], old_path: kind == 'renamed' ? e[:old_path] : nil,
        author_kind: e[:author_kind], author_name: e[:author_name], first_at: e[:at], last_at: e[:at],
        first_seq: e[:seq], last_seq: e[:seq], versions: 1, files: nil,
        blob_before: kind == 'created' ? nil : e[:blob_before], blob_after: e[:blob_after], size: e[:size],
        members: [e[:id]], event: e }
    end

    def extend_entry(run, e)
      run.merge!(last_at: e[:at], last_seq: e[:seq], versions: run[:versions] + 1, blob_after: e[:blob_after],
                 size: e[:size])
      run[:members] << e[:id]
    end

    # Folder bursts replace the entries of the files they take
    def folders(entries, keeps)
      return finish(entries) if keeps.empty?

      singles = entries.select { %w[deleted renamed].include?(_1[:kind]) }.map { _1[:event] }
      taken = {}
      folders = []
      %w[deleted renamed].each do |action|
        items = (singles.select { _1[:action] == action } + keeps.select { _1[:action] == action })
        items.group_by { [_1[:author_kind], _1[:author_name]] }.each_value do |list|
          bursts(list.sort_by { [_1[:seq], _1[:id]] }).each { |run| folders.concat(folders_in(run, action, taken)) }
        end
      end
      finish(entries.reject { taken[_1[:id]] } + folders)
    end

    # A run: each item less than BURST_GAP after the previous one
    def bursts(list)
      list.slice_when { |a, b| b[:at] - a[:at] >= BURST_GAP }.to_a
    end

    def folders_in(run, action, taken)
      keep_dir = ->(path) { File.dirname(path) }
      moved = run.select { role(_1) == :keep }.to_h { [keep_dir.(action == 'renamed' ? _1[:old_path] : _1[:path]), _1] }
      tops = moved.keys.reject { |dir| moved.keys.any? { dir.start_with?("#{_1}/") } }
      tops.map do |from|
        to = action == 'renamed' ? keep_dir.(moved[from][:path]) : nil
        members = run.select do |e|
          next false if taken[e[:id]]

          old = action == 'renamed' ? e[:old_path] : e[:path]
          old.start_with?("#{from}/") && (to.nil? || e[:path] == "#{to}/#{old.delete_prefix("#{from}/")}")
        end
        members.each { taken[_1[:id]] = true }
        files = members.count { role(_1) == :file }
        { id: members.map { _1[:id] }.min, kind: "folder_#{action}", path: to || from, old_path: to && from,
          author_kind: members.first[:author_kind], author_name: members.first[:author_name],
          first_at: members.map { _1[:at] }.min, last_at: members.map { _1[:at] }.max,
          first_seq: members.map { _1[:seq] }.min, last_seq: members.map { _1[:seq] }.max, versions: members.size,
          files:, blob_before: nil, blob_after: nil, size: nil, members: members.map { _1[:id] },
          member_paths: members.select { role(_1) == :file }.flat_map { [_1[:path], _1[:old_path]] }.compact }
      end
    end

    # Rows for history_entries (+ :members): search keys, no working fields
    def finish(entries)
      entries.map do |entry|
        # A folder as `A/`: typing the folder's path with its slash finds it
        folder = entry[:kind].start_with?('folder_')
        paths = [entry[:path], entry[:old_path]].compact.map { folder ? "#{_1}/" : _1 } + entry[:member_paths].to_a
        entry.except(:event, :member_paths).merge(author_key: entry[:author_name].downcase,
                                                  search: paths.map(&:downcase).join("\n"))
      end
    end
  end
end
