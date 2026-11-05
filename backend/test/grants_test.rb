# frozen_string_literal: false
# Grants: what a token's form may save (Grants.check), the union of modes (Access), and migration 004 from the
# one-vault grants table
require_relative 'test_helper'

class GrantsTest < VaultTest
  def setup
    super
    Vault.create('work')
  end

  # [vault:]folder => mode, in order → rows
  def rows(grants)
    grants.map do |at, mode|
      vault, folder = at.include?(':') ? at.split(':', 2) : ['test', at]
      { vault:, folder:, mode: }
    end
  end

  def errors(grants) = Grants.check(rows(grants))

  def test_nested_grants_only_add
    assert_equal({}, errors('Claude' => 'r', 'Claude/Inbox' => 'rw'))
    assert_equal({}, errors('Claude' => 'w', 'Claude/Inbox' => 'r'))
    assert_equal({ 1 => '`r` on Claude/Inbox has no effect: Claude already gives rw.' },
                 errors('Claude' => 'rw', 'Claude/Inbox' => 'r'))
    assert_equal({ 0 => '`rw` on Claude/Inbox has no effect: Claude already gives rw.' },
                 errors('Claude/Inbox' => 'rw', 'Claude' => 'rw'), 'the nested row, wherever it is')
    assert_equal({ 1 => '`w` on Claude/Inbox has no effect: Claude already gives w.' }, errors('Claude' => 'w', 'Claude/Inbox' => 'w'))
    assert_equal({ 2 => '`rw` on Claude/A/B has no effect: Claude + Claude/A already give rw.' },
                 errors('Claude' => 'r', 'Claude/A' => 'w', 'Claude/A/B' => 'rw'))
  end

  def test_by_segment_and_by_vault
    assert_equal({}, errors('Claude' => 'rw', 'Claude2' => 'r', 'work:Claude/Inbox' => 'r'))
  end

  def test_folders
    assert_equal 'Claude/Inbox', Grants.normalize(' /Claude/Inbox/ ')
    assert_equal '', Grants.normalize('/')
    assert_equal({}, errors('' => 'r', 'Inbox' => 'w'), 'the whole vault')
    assert_equal({ 1 => '`r` on Inbox has no effect: / already gives rw.' }, errors('' => 'rw', 'Inbox' => 'r'))
    ['..', 'a/../b', './a', 'a//b', '.obsidian', 'Inbox/.trash'].each do |folder|
      assert_match(/can't be granted/, errors(folder => 'w')[0], folder)
    end
    assert_equal({ 1 => '`Inbox` is in test twice.' }, errors('Inbox' => 'w', 'test:Inbox' => 'r'))
  end

  def test_vaults_modes_and_none
    assert_equal({ 0 => 'No vault `nope`.' }, errors('nope:Inbox' => 'w'))
    assert_equal({ 0 => 'No vault picked.' }, Grants.check([{ vault: '', folder: 'Inbox', mode: 'w' }]))
    assert_equal({ 0 => 'Bad mode `x`.' }, errors('Inbox' => 'x'))
    assert_equal({ base: 'Add at least one grant.' }, Grants.check([]))
  end

  def test_purposes
    token, = Devices.create_scoped(name: 'claude', grants: [{ vault: 'test', folder: 'Claude', mode: 'rw', purpose: 'Memory.' },
                                                            { vault: 'test', folder: 'Inbox', mode: 'w' }])
    assert_equal [['Claude', 'Memory.'], ['Inbox', '']], Grants.of(token.id).map { [_1.folder, _1.purpose] }
    assert_equal "a\nb\n\nc", Grants.normalize_purpose(" a\r\nb\r\n\rc \n")
    assert_equal({ 0 => 'The purpose is 2001 characters, at most 2000.' },
                 Grants.check([{ vault: 'test', folder: 'Inbox', mode: 'w', purpose: 'ё' * 2001 }]))
    assert_equal({}, Grants.check([{ vault: 'test', folder: 'Inbox', mode: 'w', purpose: 'ё' * 2000 }]))
  end

  def test_save_replaces_all_or_nothing
    token, = Devices.create_scoped(name: 'claude', grants: rows('Inbox' => 'w', 'work:Notes' => 'rw'))
    assert_equal [%w[test Inbox w], %w[work Notes rw]], Grants.of(token.id).map { [_1.vault, _1.folder, _1.mode] }
    refute_empty Grants.save(token.id, rows('Inbox' => 'rw', 'Inbox/Sub' => 'r'))
    assert_equal 2, Grants.of(token.id).size, 'nothing saved'
    assert_empty Grants.save(token.id, rows('Journal' => 'r'))
    assert_equal [%w[test Journal r]], Grants.of(token.id).map { [_1.vault, _1.folder, _1.mode] }
  end

  def test_union_of_modes
    grants = rows('Claude' => 'r', 'Claude/Inbox' => 'w', 'work:Claude' => 'w').map { Grants::Grant.new(id: 0, purpose: '', **_1) }
    assert_equal 'r', Access.mode(grants, 'test', 'Claude/x.md')
    assert_equal 'rw', Access.mode(grants, 'test', 'Claude/Inbox/x.md')
    assert_equal '', Access.mode(grants, 'test', 'Claude2/x.md')
    assert_equal 'w', Access.mode(grants, 'work', 'Claude/Inbox/x.md')
    refute Access.allowed?(grants, 'test', 'Claude/Inbox/.hidden/x.md', :w)
  end

  # A database at 003 (grants in `grants`, one vault per token) → 004: the same rows in scoped_token_grants
  def test_migration_from_one_vault_grants
    path = File.join(@root, 'old.db')
    db = Sequel.sqlite(path)
    Sequel::Migrator.run(db, DB::MIGRATIONS, target: 3)
    vault = db[:vaults].insert(name: 'notes', created_at: Time.now)
    token = db[:devices].insert(name: 'claude', kind: 'scoped', token_sha256: 'a' * 64, created_at: Time.now)
    db[:grants].import(%i[token_id vault_id folder mode], [[token, vault, '', 'w'], [token, vault, 'Inbox', 'rw']])

    Sequel::Migrator.run(db, DB::MIGRATIONS)
    refute db.table_exists?(:grants)
    assert_equal [''], db[:scoped_token_grants].select_map(:purpose).uniq, '005: no purpose yet'
    assert_equal [['', 'w'], %w[Inbox rw]], db[:scoped_token_grants].where(token_id: token).order(:folder).select_map(%i[folder mode])
    assert_raises(Sequel::UniqueConstraintViolation) { db[:scoped_token_grants].insert(token_id: token, vault_id: vault, folder: 'Inbox', mode: 'r') }
    assert_raises(Sequel::CheckConstraintViolation) { db[:scoped_token_grants].insert(token_id: token, vault_id: vault, folder: 'X', mode: 'x') }
  ensure
    db&.disconnect
  end
end
