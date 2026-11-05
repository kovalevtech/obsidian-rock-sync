require_relative 'test_helper'

class VaultRecordTest < VaultTest
  def test_create_adds_the_row_and_the_repo
    vault = Vault.create('notes')
    assert_equal %w[notes test], Vault.names
    assert Dir.exist?(File.join(@vaults_dir, 'notes', 'repo.git'))
    assert_same vault, Vault.find('notes')
    assert_raises(ArgumentError) { Vault.create('notes') }
    assert_raises(ArgumentError) { Vault.create('Notes') }
  end

  # The database decides which vaults exist, not VAULTS_DIR
  def test_find_needs_the_row_and_the_repo
    Vault.new('stray', File.join(@vaults_dir, 'stray')).setup!
    assert_nil Vault.find('stray')

    FileUtils.rm_rf(File.join(@vaults_dir, 'test', 'repo.git'))
    assert_nil Vault.find('test')
  end

  def test_create_adopts_an_existing_repo
    Vault.new('stray', File.join(@vaults_dir, 'stray')).setup!
    assert Vault.create('stray')
  end

  def test_create_needs_the_vaults_directory
    FileUtils.rm_rf(@vaults_dir)
    assert_raises(ArgumentError) { Vault.create('notes') }
    refute Dir.exist?(@vaults_dir)
    assert_equal %w[test], Vault.names
  end

  def test_sizes
    assert_equal({ files: 0, history: @vault.sizes[:history], total: @vault.sizes[:history] }, @vault.sizes)
    commit_file('a.md', 'a' * 100)
    commit_file('a.md', 'b' * 50)
    commit_file('b.md', 'c' * 10)
    sizes = @vault.sizes
    assert_equal 60, sizes[:files], 'the current version only'
    expected = Dir.glob("#{@vaults_dir}/test/repo.git/**/*", File::FNM_DOTMATCH).select { File.file?(_1) }.sum { File.size(_1) }
    assert_equal expected, sizes[:history]
    assert_equal sizes[:files] + sizes[:history], sizes[:total]
  end

  # git gc: loose objects packed, every committed version still there
  def test_compact
    hashes = (1..5).map { commit_file('a.md', "version #{_1}\n" * 1000) }
    assert_operator @vault.git.count_objects[:loose], :>, 0
    before = @vault.sizes[:history]

    thread = @vault.compact
    assert_nil @vault.compact, 'one at a time'
    thread.join
    refute @vault.compacting?
    assert_equal({ loose: 0, packs: 1 }, @vault.git.count_objects)
    hashes.each_with_index { |hash, i| assert_equal "version #{i + 1}\n" * 1000, @vault.git.cat_file(hash) }
    assert_equal before, @vault.compaction[:before]
    assert_equal @vault.sizes[:history], @vault.compaction[:after] # tiny repos grow (pack + index): no "smaller" here
    assert_nil @vault.compaction[:error]
  end

  def test_check
    Vault.check!
    FileUtils.rm_rf(File.join(@vaults_dir, 'test', 'repo.git'))
    error = assert_raises(RuntimeError) { Vault.check! }
    assert_equal "vault test missing: no #{@vaults_dir}/test/repo.git", error.message
  end
end
