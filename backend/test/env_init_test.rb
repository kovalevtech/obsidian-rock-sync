require_relative 'test_helper'

# INIT_VAULT_NAME, INIT_VAULT_CODE: what a boot makes of them (through config.ru: boot_test.rb)
class EnvInitTest < VaultTest
  CODE = '482913'

  def init(vault: 'notes', code: CODE)
    capture_io { EnvInit.call(Config::Init.new(vault:, code:)) }.first
  end

  def codes = DB[:pairings].select_map(:code)

  def test_nothing_to_do
    assert_nil EnvInit.call(nil)
  end

  def test_makes_the_vault_and_a_code_without_expiry
    output = init
    assert Vault.find('notes')
    assert_equal [CODE], codes
    assert_nil DB[:pairings].first[:expires_at]
    refute_includes output, CODE

    status, device, = Pairings.redeem(CODE, 'pixel', now: Time.now + 365 * 24 * 60 * 60)
    assert_equal :paired, status
    assert_equal 'notes', device.vault
  end

  def test_a_vault_without_a_code
    init(code: nil)
    assert Vault.find('notes')
    assert_empty codes
  end

  def test_a_second_boot_keeps_one_code
    init
    assert_includes init, 'open for the first device'
    assert_equal [CODE], codes
  end

  def test_another_value_replaces_the_code_and_none_drops_it
    init
    init(code: '111111')
    assert_equal ['111111'], codes
    EnvInit.call(nil)
    assert_empty codes
  end

  def test_once_used_never_again
    init
    assert_equal :paired, Pairings.redeem(CODE, 'pixel').first
    assert_empty codes
    assert_includes init, 'ignored, notes has its devices already'
    assert_empty codes
  end

  def test_a_revoked_first_device_counts
    init(code: nil)
    device, = Devices.create(name: 'pixel', vault: 'notes')
    Devices.revoke(device.id)
    init
    assert_empty codes
  end

  def test_burned_codes_come_back_on_the_next_boot
    init
    Pairings::ATTEMPTS.reset
    Pairings::MAX_WRONG.times { Pairings.redeem('000000', 'x') }
    assert_empty codes
    init
    assert_equal [CODE], codes
  end

  def test_keeps_a_repo_already_there
    init(code: nil)
    WriteFile.call(Vault.find('notes'), 'a.md', "a\n", if_none_match: '*')
    head = Vault.find('notes').version
    DB[:vaults].where(name: 'notes').delete
    init(code: nil)
    assert_equal head, Vault.find('notes').version
  end

  def test_bad_names
    assert_raises(ArgumentError) { init(vault: 'Bad Name') }
  end
end
