# frozen_string_literal: false
require_relative 'test_helper'

class WriteFileTest < VaultTest
  def test_written
    assert_equal [:written, blob("a\n")], WriteFile.call(@vault, 'd/a.md', "a\n", if_none_match: '*')
    assert_equal "a\n", File.read(tree_file('d/a.md'))
    assert_equal 'PUT d/a.md', last_commit_message
    assert_equal [:written, blob("b\n")], WriteFile.call(@vault, 'd/a.md', "b\n", if_match: blob("a\n"))
  end

  def test_unchanged_whatever_the_headers
    commit_file('a.md', "a\n")
    count = commit_count
    assert_equal [:unchanged, blob("a\n")], WriteFile.call(@vault, 'a.md', "a\n", if_none_match: '*')
    assert_equal [:unchanged, blob("a\n")], WriteFile.call(@vault, 'a.md', "a\n", if_match: 'f' * 40)
    assert_equal count, commit_count
  end

  def test_create_only_on_an_existing_file
    commit_file('a.md', "server\n")
    status, etag, body, modified_at = WriteFile.call(@vault, 'a.md', "mine\n", if_none_match: '*')
    assert_equal [:stale, blob("server\n"), "server\n"], [status, etag, body]
    assert_kind_of Time, modified_at
  end

  def test_merged_and_committed
    base = commit_file('a.md', "1\n2\n3\n4\n5\n")
    commit_file('a.md', "1 server\n2\n3\n4\n5\n")
    merged = "1 server\n2\n3\n4\n5 mine\n"
    assert_equal [:merged, blob(merged), merged], WriteFile.call(@vault, 'a.md', "1\n2\n3\n4\n5 mine\n", if_match: base, mergeable: true)
    assert_equal merged, File.read(tree_file('a.md'))
    assert_equal 'MERGE a.md', last_commit_message
  end

  def test_merge_resulting_in_the_server_version_commits_nothing
    base = commit_file('a.md', "1\n2\n3\n4\n5\n")
    server = commit_file('a.md', "1 server\n2\n3\n4\n5 mine\n")
    count = commit_count
    # mine's change is already there: the merge equals the server version
    assert_equal [:merged, server, "1 server\n2\n3\n4\n5 mine\n"], WriteFile.call(@vault, 'a.md', "1\n2\n3\n4\n5 mine\n", if_match: base, mergeable: true)
    assert_equal count, commit_count
  end

  def test_conflict_writes_nothing
    base = commit_file('a.md', "1\n2\n3\n")
    server = commit_file('a.md', "1\n2 server\n3\n")
    count = commit_count
    status, etag, body, = WriteFile.call(@vault, 'a.md', "1\n2 mine\n3\n", if_match: base, mergeable: true)
    assert_equal [:conflict, server], [status, etag]
    assert_includes body, "=========\n2 mine\n"
    assert_equal count, commit_count
    assert_equal "1\n2 server\n3\n", File.read(tree_file('a.md'))
  end

  def test_not_mergeable_is_stale_and_writes_nothing
    base = commit_file('a.svg', "<svg>\n1\n2\n3\n</svg>\n")
    server = commit_file('a.svg', "<svg>\n1 server\n2\n3\n</svg>\n")
    count = commit_count
    assert_equal [:stale, server, "<svg>\n1 server\n2\n3\n</svg>\n"],
                 WriteFile.call(@vault, 'a.svg', "<svg>\n1\n2\n3 mine\n</svg>\n", if_match: base).first(3)
    assert_equal count, commit_count
  end

  def test_unknown_base_is_stale
    server = commit_file('a.md', "server\n")
    assert_equal [:stale, server, "server\n"], WriteFile.call(@vault, 'a.md', "mine\n", if_match: 'f' * 40).first(3)
  end

  def test_gone_is_stale_without_a_version
    commit_file('other.md', "o\n")
    assert_equal [:stale], WriteFile.call(@vault, 'gone.md', "mine\n", if_match: blob("old\n"))
    refute File.exist?(tree_file('gone.md'))
  end
end
