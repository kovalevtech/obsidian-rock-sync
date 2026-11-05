require_relative 'test_helper'

class DevicesTest < VaultTest
  def id_of(name) = DB[:devices].where(name:).get(:id)

  def test_authenticate_by_sha256
    device, failure = Devices.authenticate(@token)
    assert_nil failure
    assert_equal Devices::Device.new(id: id_of('test-device'), name: 'test-device', vault: 'test'), device
    assert_equal Devices.digest(@token), DB[:devices].where(name: 'test-device').get(:token_sha256)
    assert_equal [nil, :unknown], Devices.authenticate('x' * 43)
    assert_equal [nil, :unknown], Devices.authenticate(nil)
  end

  def test_create
    device, token = Devices.create(name: 'pixel', vault: 'test')
    assert_match(/\A[A-Za-z0-9_-]{43}\z/, token) # 32 bytes, base64url without padding
    assert_equal [device, nil], Devices.authenticate(token)
    assert_equal 'pixel', device.name
    refute_includes DB[:devices].all.flat_map(&:values), token # only its hash
  end

  def test_create_refuses
    {
      'bad name' => { name: 'Pixel 7', vault: 'test' },
      'long name' => { name: 'a' * 65, vault: 'test' },
      'no vault' => { name: 'pixel', vault: nil },
      'no such vault' => { name: 'pixel', vault: 'missing' }
    }.each do |why, args|
      assert_raises(ArgumentError, why) { Devices.create(**args) }
    end
    assert_equal ['test-device'], DB[:devices].select_map(:name)
  end

  # A name is the commit author, not an identity: tokens of either kind may share it
  def test_names_may_repeat
    Devices.revoke(id_of('test-device'))
    _, second = Devices.create(name: 'test-device', vault: 'test')
    _, scoped = Devices.create_scoped(name: 'test-device')
    assert_equal 3, DB[:devices].where(name: 'test-device').count
    assert_equal 'test-device', Devices.authenticate(second).first.name
    assert_equal 'test-device', Devices.authenticate(scoped, kind: 'scoped').first.name
  end

  def test_rotate
    id = id_of('test-device')
    token = Devices.rotate(id)
    assert_equal [nil, :unknown], Devices.authenticate(@token)
    device, = Devices.authenticate(token)
    assert_equal [id, 'test-device', 'test'], [device.id, device.name, device.vault]
  end

  def test_revoke
    id = id_of('test-device')
    assert Devices.revoke(id)
    refute Devices.revoke(id), 'already revoked'
    assert_equal [nil, :revoked], Devices.authenticate(@token)
  end

  def test_list
    Vault.create('other')
    Devices.create(name: 'a-phone', vault: 'other')
    Devices.revoke(id_of('a-phone'))
    list = Devices.list
    assert_equal [%w[a-phone other], %w[test-device test]], list.map { _1.values_at(:name, :vault) }
    assert list.first[:revoked_at]
    assert_nil list.last[:revoked_at]
  end

  def test_touch_writes_at_most_every_five_minutes
    id = id_of('test-device')
    seen = -> { DB[:devices].where(id:).get(:last_seen_at) }
    t0 = Time.utc(2026, 10, 21, 12)
    Devices.touch(id, now: t0)
    assert_equal t0, seen.call
    Devices.touch(id, now: t0 + 299)
    assert_equal t0, seen.call
    Devices.touch(id, now: t0 + 301)
    assert_equal t0 + 301, seen.call
  end

  # A database at 007 (device_vaults) → 008: a token with one vault keeps it, one with several or none goes, with its
  # Reconnect codes; scoped tokens stay, without a vault
  def test_migration_to_one_vault
    path = File.join(@root, 'old.db')
    db = Sequel.sqlite(path, foreign_keys: true)
    Sequel::Migrator.run(db, DB::MIGRATIONS, target: 7)
    notes, work = %w[notes work].map { db[:vaults].insert(name: _1, created_at: Time.now) }
    add = ->(name, kind = 'device') { db[:devices].insert(name:, kind:, token_sha256: Devices.digest(name), created_at: Time.now) }
    phone, laptop, empty, claude = add['phone'], add['laptop'], add['empty'], add['claude', 'scoped']
    db[:device_vaults].import(%i[device_id vault_id], [[phone, work], [laptop, notes], [laptop, work]])
    db[:pairings].insert(code: '123456', vault_id: notes, device_id: laptop, expires_at: Time.now + 60)
    db[:pairings].insert(code: '654321', vault_id: work, device_id: phone, expires_at: Time.now + 60)

    Sequel::Migrator.run(db, DB::MIGRATIONS)
    refute db.table_exists?(:device_vaults)
    assert_equal [[phone, work], [claude, nil]], db[:devices].order(:id).select_map(%i[id vault_id])
    assert_equal ['654321'], db[:pairings].select_map(:code)
    assert_empty db[:devices].where(id: empty)
    assert_raises(Sequel::CheckConstraintViolation, 'the CHECK on kind kept') { add['x', 'other'] }
  ensure
    db&.disconnect
  end

  # 009 rebuilds devices without UNIQUE on name: grants and codes pointing at its rows stay
  def test_migration_names_not_unique
    path = File.join(@root, 'old.db')
    db = Sequel.sqlite(path, foreign_keys: true)
    Sequel::Migrator.run(db, DB::MIGRATIONS, target: 8)
    vault = db[:vaults].insert(name: 'notes', created_at: Time.now)
    add = ->(name, kind = 'device', vault_id = vault) { db[:devices].insert(name:, kind:, vault_id:, token_sha256: Devices.digest("#{name}#{kind}"), created_at: Time.now) }
    phone, claude = add['phone'], add['claude', 'scoped', nil]
    db[:scoped_token_grants].insert(token_id: claude, vault_id: vault, folder: 'Inbox', mode: 'rw')
    db[:pairings].insert(code: '123456', vault_id: vault, device_id: phone, expires_at: Time.now + 60)
    assert_raises(Sequel::UniqueConstraintViolation) { add['phone', 'scoped', nil] }

    Sequel::Migrator.run(db, DB::MIGRATIONS)
    add['phone', 'scoped', nil]
    assert_equal 2, db[:devices].where(name: 'phone').count
    assert_equal [claude], db[:scoped_token_grants].select_map(:token_id)
    assert_equal [phone], db[:pairings].select_map(:device_id)
    db[:devices].where(id: phone).delete
    assert_empty db[:pairings], 'the cascade still points at devices'
    assert_raises(Sequel::CheckConstraintViolation, 'the CHECK on kind kept') { add['x', 'other'] }
    assert_raises(Sequel::CheckConstraintViolation, 'the CHECK on name kept') { add['Not A Name'] }
  ensure
    db&.disconnect
  end
end
