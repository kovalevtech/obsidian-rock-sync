# frozen_string_literal: false
require_relative 'test_helper'

class MergeVersionsTest < VaultTest
  def setup
    super
    @base = commit_file('a.md', "1\n2\n3\n4\n5\n")
    @server = commit_file('a.md', "1 server\n2\n3\n4\n5\n")
  end

  def test_clean
    status, etag, body, modified_at = MergeVersions.call(@vault, 'a.md', "1\n2\n3\n4\n5 mine\n", base: @base, mergeable: true)
    assert_equal :clean, status
    assert_equal @server, etag
    assert_equal "1 server\n2\n3\n4\n5 mine\n", body
    assert_kind_of Time, modified_at
  end

  def test_conflict_server_first_with_9_char_markers
    status, etag, body, modified_at = MergeVersions.call(@vault, 'a.md', "1 mine\n2\n3\n4\n5\n", base: @base, mergeable: true)
    assert_equal :conflict, status
    assert_equal @server, etag
    label = "server #{modified_at.getutc.strftime('%Y-%m-%dT%H:%MZ')}"
    assert_equal "#{'<' * 9} #{label}\n1 server\n#{'=' * 9}\n1 mine\n#{'>' * 9} mine\n2\n3\n4\n5\n", body
  end

  def test_unknown_base_is_stale_with_the_server_version
    assert_equal [:stale, @server, "1 server\n2\n3\n4\n5\n"], MergeVersions.call(@vault, 'a.md', "x\n", base: 'f' * 40, mergeable: true).first(3)
  end

  # Sent as text, yet binary: git refuses
  def test_binary_is_stale
    base = commit_file('b.bin', "\0\1\2".b)
    server = commit_file('b.bin', "\0\1\3".b)
    status, etag, = MergeVersions.call(@vault, 'b.bin', "\0\2\2".b, base:, mergeable: true)
    assert_equal [:stale, server], [status, etag]
  end

  def test_not_mergeable_is_stale_and_keeps_nothing
    mine = "1\n2\n3\n4\n5 mine\n"
    assert_equal [:stale, @server, "1 server\n2\n3\n4\n5\n"], MergeVersions.call(@vault, 'a.md', mine, base: @base).first(3)
    assert_nil @vault.git.cat_file(blob(mine))
  end

  def test_missing_file
    assert_raises(Vault::NotFound) { MergeVersions.call(@vault, 'gone.md', "x\n", base: @base, mergeable: true) }
  end

  def test_writes_nothing_but_keeps_mine_as_a_blob
    count = commit_count
    MergeVersions.call(@vault, 'a.md', "1 mine\n2\n3\n4\n5\n", base: @base, mergeable: true)
    assert_equal count, commit_count
    assert_equal "1 server\n2\n3\n4\n5\n", File.read(tree_file('a.md'))
    assert_equal "1 mine\n2\n3\n4\n5\n", @vault.git.cat_file(blob("1 mine\n2\n3\n4\n5\n"))
  end
end
