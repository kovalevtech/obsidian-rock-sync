# The admin's history index (History, History::Grouping) over real commits: catching up, rebuilding, grouping, folder
# bursts, the tabs and filters. Commit times are set through git's environment (the server's git inherits it); the pages
# themselves: admin_test.rb
require_relative 'test_helper'

class HistoryTest < VaultTest
  T0 = 1_780_000_000

  def setup
    super
    @phone = Vault::Author.new(name: 'phone', kind: 'device')
    @laptop = Vault::Author.new(name: 'laptop', kind: 'device')
    @claude = Vault::Author.new(name: 'Claude', kind: 'token', client: 'mcp')
  end

  def teardown
    ENV.delete('GIT_COMMITTER_DATE')
    ENV.delete('GIT_AUTHOR_DATE')
    History.sync_limit = nil
    super
  end

  # Commits made in the block carry this time (seconds after T0)
  def at(seconds)
    ENV['GIT_COMMITTER_DATE'] = ENV['GIT_AUTHOR_DATE'] = "@#{T0 + seconds} +0000"
    yield
  ensure
    ENV.delete('GIT_COMMITTER_DATE')
    ENV.delete('GIT_AUTHOR_DATE')
  end

  def put(path, content, author: @phone, t: 0, message: "PUT #{path}")
    at(t) { @vault.commit(message, write: { path => content }, author:) }
  end

  def entries(**filters)
    History.index!(@vault)
    History.entries(@vault, limit: 1000, **filters).first
  end

  def kinds(**filters) = entries(**filters).map { [_1[:kind], _1[:path]] }

  def events = DB[:history_events].order(:id).all

  # Index

  def test_catch_up_indexes_only_new_commits
    put 'a.md', '1'
    put 'b.md', '1'
    History.index!(@vault)
    before = events
    assert_equal 2, before.size
    put 'a.md', '2', t: 5

    History.index!(@vault)
    after = events
    assert_equal before.map { _1.except(:entry_id) }, after.first(2).map { _1.except(:entry_id) }
    assert_equal [[3, 'a.md', 'modified']], after.drop(2).map { [_1[:seq], _1[:path], _1[:action]] }
    assert_equal @vault.version, DB[:history_state].get(:head)
    # Nothing new: nothing runs
    History.index!(@vault)
    assert_equal after, events
  end

  def test_a_rewritten_history_is_rebuilt
    put 'a.md', '1'
    keep = @vault.version
    put 'b.md', '1'
    History.index!(@vault)
    assert_equal %w[a.md b.md], events.map { _1[:path] }

    # A "delete forever": HEAD moved to a commit that doesn't descend from the last one indexed
    git('update-ref', 'HEAD', keep)
    put 'c.md', '1'
    assert_equal [%w[created c.md], %w[created a.md]], kinds
    assert_equal %w[a.md c.md], events.map { _1[:path] }
  end

  def test_deleted_rows_are_rebuilt_the_same
    put 'a.md', '1'
    put 'a.md', '2', t: 2
    put 'b.md', '1', t: 3
    first = kinds
    %i[history_entries history_events history_state].each { DB[_1].delete }
    assert_equal first, kinds
  end

  def test_concurrent_catch_ups_dont_duplicate
    20.times { put "n#{_1}.md", 'x' }
    4.times.map { Thread.new { History.index!(@vault) } }.each(&:join)
    assert_equal 20, events.size
    assert_equal 20, DB[:history_entries].count
    # And the key itself refuses a second row for a commit's path
    assert_raises(Sequel::UniqueConstraintViolation) { DB[:history_events].insert(events.first.except(:id)) }
  end

  def test_a_commit_touching_many_files
    files = 30.times.to_h { ["Imported/n#{_1}.md", "note #{_1}"] }
    @vault.commit('initial import', write: files.merge('Imported/.keep' => ''))
    assert_equal files.keys.sort, entries.map { _1[:path] }.sort
    assert_equal 31, events.size
    assert(entries.all? { _1[:kind] == 'created' && _1[:author_kind] == 'unknown' })
  end

  def test_renames_found_without_the_message
    put 'a.md', "a longer note\nwith lines\n"
    at(60) { @vault.commit('something', write: { 'b.md' => "a longer note\nwith lines\n" }, remove: ['a.md'], author: @phone) }
    assert_equal [%w[renamed b.md], %w[created a.md]], kinds
    assert_equal 'a.md', entries.first[:old_path]
  end

  def test_background_build
    put 'a.md', '1'
    History.sync_limit = 0
    assert_equal :indexing, History.catch_up(@vault)
    History.thread(@vault).join
    History.sync_limit = nil
    assert_equal :current, History.catch_up(@vault)
    assert_equal [%w[created a.md]], kinds
  end

  # Grouping

  def test_autosaves_are_one_entry
    put 'a.md', '0', t: 0
    1.upto(10) { put 'a.md', _1.to_s, t: _1 * 2 }
    entry, = entries
    assert_equal ['created', 11, T0, T0 + 20], entry.values_at(:kind, :versions, :first_at, :last_at)
  end

  def test_the_window_slides
    0.upto(12) { put 'a.md', _1.to_s, t: _1 * 14 * 60 } # 14 min apart, nearly three hours
    assert_equal [13], entries.map { _1[:versions] }
  end

  def test_a_gap_of_16_minutes_splits
    put 'a.md', '1'
    put 'a.md', '2', t: 60
    put 'a.md', '3', t: 60 + 16 * 60
    assert_equal [['edited', 1], ['created', 2]], entries.map { _1.values_at(:kind, :versions) }
  end

  def test_another_author_in_between_splits
    put 'a.md', '1'
    put 'a.md', '2', t: 2, author: @laptop
    put 'a.md', '3', t: 4
    assert_equal [%w[edited phone], %w[edited laptop], %w[created phone]], entries.map { _1.values_at(:kind, :author_name) }
  end

  def test_other_files_in_between_dont_split
    put 'a.md', '1'
    put 'b.md', '1', t: 2
    put 'a.md', '2', t: 4
    put 'b.md', '2', t: 6, author: @laptop
    put 'a.md', '3', t: 8
    assert_equal [['a.md', 3], ['b.md', 1], ['b.md', 1]], entries.map { _1.values_at(:path, :versions) }
  end

  def test_merges_and_appends_join_the_run
    put 'a.md', "one\ntwo\nthree\n"
    base = blob("one\ntwo\nthree\n")
    put 'a.md', "one\ntwo\nthree\nfour\n", t: 2
    at(4) { assert_equal :merged, WriteFile.call(@vault, 'a.md', "zero\none\ntwo\nthree\n", if_match: base, mergeable: true, author: @phone).first }
    at(6) { assert_equal :appended, AppendFile.call(@vault, 'a.md', 'five', author: @phone).first }
    assert_equal %w[MERGE APPEND], git('log', '-2', '--format=%s').lines.map { _1.split.first }.reverse
    assert_equal [['created', 4]], entries.map { _1.values_at(:kind, :versions) }
  end

  def test_a_rename_and_a_delete_end_a_run
    put 'a.md', '1'
    put 'a.md', '2', t: 2
    at(4) { MoveFile.call(@vault, 'a.md', 'b.md', author: @phone) }
    put 'b.md', '3', t: 6
    put 'b.md', '4', t: 8
    at(10) { DeleteFile.call(@vault, 'b.md', if_match: blob('4'), author: @phone) }
    put 'b.md', 'again', t: 12
    assert_equal [%w[created b.md], %w[deleted b.md], %w[edited b.md], %w[renamed b.md], %w[created a.md]], kinds
    edited = entries.find { _1[:kind] == 'edited' }
    assert_equal [2, blob('2'), blob('4')], edited.values_at(:versions, :blob_before, :blob_after)
  end

  def test_hidden_paths_and_keeps_are_never_entries
    put '.plugins/p/data.json', '{}'
    put 'A/.keep', ''
    put 'A/.hidden/x.md', 'x'
    put 'A/x.md', 'x', t: 2
    assert_equal [%w[created A/x.md]], kinds
    assert_empty entries(path: 'plugins')
  end

  # Folders, as the plugin sends them: a commit per file, one for the .keep

  def folder(prefix = 'Projects')
    put "#{prefix}/.keep", ''
    put "#{prefix}/a.md", 'a'
    put "#{prefix}/Sub/.keep", ''
    put "#{prefix}/Sub/b.md", 'b'
    put 'Other/c.md', 'c'
  end

  def test_a_folder_delete_is_one_entry
    folder
    # Obsidian reports the files, then the folders (order doesn't matter)
    at(3600) { DeleteFile.call(@vault, 'Projects/Sub/b.md', if_match: blob('b'), author: @phone) }
    at(3601) { DeleteFile.call(@vault, 'Projects/a.md', if_match: blob('a'), author: @phone) }
    at(3602) { DeleteFile.call(@vault, 'Projects/Sub/.keep', if_match: blob(''), author: @phone) }
    at(3603) { DeleteFile.call(@vault, 'Projects/.keep', if_match: blob(''), author: @phone) }
    folder_entry, *rest = entries
    assert_equal ['folder_deleted', 'Projects', 2, T0 + 3600, T0 + 3603], folder_entry.values_at(:kind, :path, :files, :first_at, :last_at)
    assert_equal %w[Projects/.keep Projects/Sub/.keep Projects/Sub/b.md Projects/a.md],
                 History.events(folder_entry).map { _1[:path] }.sort
    assert_equal %w[created], rest.map { _1[:kind] }.uniq
    assert_equal [%w[folder_deleted Projects]], kinds(tab: :deleted)
  end

  def test_a_folder_rename_is_one_entry
    folder
    at(3600) { MoveFile.call(@vault, 'Projects/.keep', 'Done/.keep', author: @phone) }
    at(3601) { MoveFile.call(@vault, 'Projects/a.md', 'Done/a.md', author: @phone) }
    at(3601) { MoveFile.call(@vault, 'Projects/Sub/.keep', 'Done/Sub/.keep', author: @phone) }
    at(3602) { MoveFile.call(@vault, 'Projects/Sub/b.md', 'Done/Sub/b.md', author: @phone) }
    moved, = entries
    assert_equal %w[folder_renamed Done Projects], moved.values_at(:kind, :path, :old_path)
    assert_equal 2, moved[:files]
    assert_equal [%w[folder_renamed Done]], kinds(tab: :moves)
  end

  # A slow burst (20 files 50 s apart, longer than WINDOW) with the page opened before its .keep: the tail reaches back
  # along the chain, not just WINDOW
  def test_a_folder_burst_cut_by_a_catch_up
    put 'Slow/.keep', ''
    20.times { put "Slow/n#{_1}.md", _1.to_s }
    20.times { |i| at(3600 + i * 50) { DeleteFile.call(@vault, "Slow/n#{i}.md", if_match: blob(i.to_s), author: @phone) } }
    History.index!(@vault)
    assert_equal 20, kinds(tab: :deleted).size
    at(3600 + 20 * 50) { DeleteFile.call(@vault, 'Slow/.keep', if_match: blob(''), author: @phone) }
    assert_equal [%w[folder_deleted Slow]], kinds(tab: :deleted)
    assert_equal 20, entries(tab: :deleted).first[:files]
  end

  def test_a_burst_of_another_author_or_after_a_pause_stays_apart
    folder
    at(3500) { DeleteFile.call(@vault, 'Projects/a.md', if_match: blob('a'), author: @phone) } # 200 s before
    at(3600) { DeleteFile.call(@vault, 'Projects/Sub/b.md', if_match: blob('b'), author: @laptop) }
    at(3700) { DeleteFile.call(@vault, 'Projects/Sub/.keep', if_match: blob(''), author: @phone) }
    at(3701) { DeleteFile.call(@vault, 'Projects/.keep', if_match: blob(''), author: @phone) }
    assert_equal [%w[folder_deleted Projects], %w[deleted Projects/Sub/b.md], %w[deleted Projects/a.md]],
                 kinds(tab: :deleted)
    assert_equal 0, entries(tab: :deleted).first[:files]
  end

  # Deleted tab

  def test_deleted_and_back
    put 'a.md', 'a'
    put 'b.md', 'b'
    at(60) { DeleteFile.call(@vault, 'a.md', if_match: blob('a'), author: @phone) }
    at(60) { DeleteFile.call(@vault, 'b.md', if_match: blob('b'), author: @laptop) }
    assert_equal [%w[deleted b.md], %w[deleted a.md]], kinds(tab: :deleted)
    put 'a.md', 'again', t: 120
    assert_equal [%w[deleted b.md]], kinds(tab: :deleted)
    deleted, = entries(tab: :deleted)
    assert_equal ['laptop', blob('b'), nil], deleted.values_at(:author_name, :blob_before, :blob_after)
  end

  # Filters

  def test_filters
    put 'Notes/Ideas.md', '1'
    put 'Notes/Ideas.md', '2', t: 3600, author: @claude
    put 'Log.md', '1', t: 7200, author: @laptop
    put 'Журнал/Запись.md', '1', t: 7200, author: @claude

    assert_equal %w[Журнал/Запись.md Notes/Ideas.md], entries(author: 'CLAU').map { _1[:path] }
    assert_equal %w[Notes/Ideas.md Notes/Ideas.md], entries(path: 'notes/').map { _1[:path] }
    assert_equal %w[Журнал/Запись.md], entries(path: 'журнал').map { _1[:path] }
    assert_empty entries(path: '%')
    assert_equal %w[Log.md], entries(since: Time.at(T0 + 3601), till: Time.at(T0 + 7201), author: 'lap').map { _1[:path] }
    assert_equal ['Notes/Ideas.md'], entries(till: Time.at(T0 + 1)).map { _1[:path] }
    assert_equal %w[Notes/Ideas.md], entries(path: 'a', author: 'claude').map { _1[:path] } # Latin a
  end

  def test_pages
    6.times { put "n#{_1}.md", 'x', t: _1 * 60, author: _1.even? ? @phone : @laptop }
    History.index!(@vault)
    page, more = History.entries(@vault, author: 'phone', limit: 2)
    assert more
    assert_equal %w[n4.md n2.md], page.map { _1[:path] }
    page, more = History.entries(@vault, author: 'phone', limit: 2, before: page.last.values_at(:last_at, :id))
    refute more
    assert_equal %w[n0.md], page.map { _1[:path] }
  end
end
