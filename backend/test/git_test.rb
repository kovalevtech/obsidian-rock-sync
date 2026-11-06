# frozen_string_literal: false
require_relative 'test_helper'

class GitTest < VaultTest
  # VAULTS_DIR mounted at another path (a container, a restore): the repo must not remember where it was created
  def test_a_vault_works_after_vaults_dir_moved
    hash = commit_file('a.md', "a\n")
    moved = "#{@vaults_dir}-moved"
    FileUtils.mv(@vaults_dir, moved)
    git = Git.new(git_dir: File.join(moved, 'test', 'repo.git'))

    assert_equal "a\n", git.cat_file(hash)
    assert_equal hash, git.hash_object("a\n")
    assert_equal({ 'a.md' => [hash, 2] }, git.ls_tree('HEAD'))
  end
end
