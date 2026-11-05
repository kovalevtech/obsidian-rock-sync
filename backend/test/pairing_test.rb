# frozen_string_literal: false
# Connecting a device with a one-time code: POST /pair over HTTP (Pairings underneath), Reconnect codes, DELETE /token,
# what it leaves in a log
require_relative 'test_helper'
require 'json'
require 'stringio'

class PairingTest < VaultTest
  include Rack::Test::Methods

  def app = App

  def setup
    super
    Pairings::ATTEMPTS.reset
  end

  def pair(code, name = 'pixel')
    post '/pair', JSON.generate(code:, name:), 'CONTENT_TYPE' => 'application/json'
    last_response
  end

  def issue(vault = 'test') = Pairings.issue(vault).first

  def wrong(code) = format('%06d', (code.to_i + 1) % 1_000_000)

  def test_a_code_gives_a_token_for_its_vault_once
    other = Vault.create('other')
    code = issue(other.name)
    res = pair(code)
    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal({ 'vault' => 'other', 'name' => 'pixel' }, body.except('token'))
    device, = Devices.authenticate(body.fetch('token'))
    assert_equal 'pixel', device.name
    assert_equal 'other', device.vault

    res = pair(code, 'second')
    assert_equal 401, res.status
    assert_equal App::UNAUTHORIZED, res.body
    refute DB[:devices].where(name: 'second').first
  end

  # A phone connects one vault after another under the name it offers: each token gets that name as it is
  def test_a_name_others_have_is_kept
    res = pair(issue, 'test-device')
    assert_equal 200, res.status
    assert_equal 'test-device', JSON.parse(res.body)['name']
    assert_equal 2, DB[:devices].where(name: 'test-device').count
  end

  def test_a_code_survives_a_restart
    code = issue
    DB.close
    assert_equal 200, pair(code).status
  end

  def test_no_row_outlives_its_code
    used = issue
    assert_equal 200, pair(used).status
    assert_empty DB[:pairings]

    issue
    assert_raises(ArgumentError) { Pairings.issue('nope') }
    assert_equal 1, DB[:pairings].count
    Pairings.issue('test', now: Time.now + Pairings::TTL + 1)
    assert_equal 1, DB[:pairings].count, 'the expired one is gone, the new one is there'
  end

  def test_spaces_in_a_code_dont_matter
    code = issue
    assert_equal 200, pair("#{code[0, 3]} #{code[3..]}").status
  end

  def test_wrong_and_expired_codes_answer_alike
    code = issue
    wrong_code = pair(wrong(code))
    assert_equal 401, wrong_code.status
    wrong_body = wrong_code.body

    status, = Pairings.redeem(code, 'late', now: Time.now + Pairings::TTL + 1)
    assert_equal :refused, status
    res = pair(code)
    assert_equal [401, wrong_body], [res.status, res.body]
    refute DB[:devices].where(name: 'late').first
  end

  def test_wrong_codes_in_a_row_burn_every_active_code
    first = issue
    second = issue
    bad = (0..).lazy.map { format('%06d', _1) }.reject { [first, second].include?(_1) }.first(Pairings::MAX_WRONG)
    bad.each { assert_equal 401, pair(_1).status }
    assert_equal 401, pair(first).status
    assert_equal 401, pair(second).status
  end

  def test_fewer_wrong_codes_burn_nothing_and_a_good_one_starts_the_count_over
    good = issue
    later = issue
    bad = (0..).lazy.map { format('%06d', _1) }.reject { [good, later].include?(_1) }.first(Pairings::MAX_WRONG - 1)
    bad.each { assert_equal 401, pair(_1).status }
    assert_equal 200, pair(good).status
    bad.each { assert_equal 401, pair(_1).status }
    assert_equal 200, pair(later, 'ipad').status
  end

  def test_wrong_codes_with_none_active_dont_burn_the_next_one
    Pairings::MAX_WRONG.times { pair('000000') }
    assert_equal 200, pair(issue).status
  end

  def test_a_bad_name_leaves_the_code_usable
    code = issue
    res = pair(code, 'Not A Name')
    assert_equal 422, res.status
    assert_includes JSON.parse(res.body)['error'], 'bad name'
    assert_equal 200, pair(code).status
  end

  def test_a_name_is_only_looked_at_under_a_good_code
    code = issue
    res = pair(wrong(code), 'Not A Name')
    assert_equal 401, res.status
    assert_equal App::UNAUTHORIZED, res.body
  end

  def test_too_many_attempts
    10.times { pair('nope') }
    code = issue
    assert_equal 429, pair(code).status
    Pairings::ATTEMPTS.reset
    assert_equal 200, pair(code).status
  end

  def test_bad_bodies
    ['', 'not json', '[1]', "{\"code\":\"#{'1' * 2000}\"}"].each do |body|
      post '/pair', body, 'CONTENT_TYPE' => 'application/json'
      assert_equal 400, last_response.status, body
    end
    post '/pair', '{}', 'CONTENT_TYPE' => 'application/json'
    assert_equal 401, last_response.status
  end

  def test_other_methods_arent_there
    get '/pair'
    assert_equal 404, last_response.status
  end

  def test_issuing_needs_a_vault_that_exists
    assert_raises(ArgumentError) { Pairings.issue('') }
    assert_raises(ArgumentError) { Pairings.issue('nope') }
  end

  def id_of(name) = DB[:devices].where(name:).get(:id)

  # Reconnect: the same row, name and vault, a new secret; the old one stops once the code is used
  def test_a_reconnect_code_gives_the_token_a_new_secret
    id = id_of('test-device')
    code, _, info = Pairings.reconnect(id)
    assert_equal({ name: 'test-device', vault: 'test' }, info)
    assert_equal :device, Devices.authenticate(@token).first ? :device : nil, 'still working until the code is used'

    res = pair(code, 'whatever')
    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal({ 'vault' => 'test', 'name' => 'test-device' }, body.except('token'))
    assert_equal [nil, :unknown], Devices.authenticate(@token)
    device, = Devices.authenticate(body['token'])
    assert_equal id, device.id
    assert_equal 1, DB[:devices].count
  end

  def test_reconnect_needs_an_active_device_token
    scoped, = Devices.create_scoped(name: 'claude')
    assert_raises(ArgumentError) { Pairings.reconnect(scoped.id) }
    Devices.revoke(id_of('test-device'))
    assert_raises(ArgumentError) { Pairings.reconnect(id_of('test-device')) }
  end

  def test_a_token_revoked_after_its_reconnect_code_stays_revoked
    code, = Pairings.reconnect(id_of('test-device'))
    Devices.revoke(id_of('test-device'))
    assert_equal 401, pair(code).status
    assert_empty DB[:pairings]
  end

  def basic(vault, token) = header('Authorization', "Basic #{["#{vault}:#{token}"].pack('m0')}")

  # The plugin's Remove: the token revokes itself, whatever the vault part says
  def test_a_token_revokes_itself
    basic('', @token)
    delete '/token'
    assert_equal 204, last_response.status
    assert_equal [nil, :revoked], Devices.authenticate(@token)
    delete '/token'
    assert_equal 401, last_response.status
  end

  # config.ru's request log: neither the code nor the token
  def test_neither_code_nor_token_in_the_log
    code = issue
    res = nil
    out, = capture_io do
      config_ru = Rack::Builder.parse_file(File.expand_path('../config.ru', __dir__))
      res = Rack::MockRequest.new(config_ru).post('/pair', input: JSON.generate(code:, name: 'pixel'), 'CONTENT_TYPE' => 'application/json')
    end
    assert_equal 200, res.status
    assert_includes out, 'paired device=pixel'
    refute_includes out, code
    refute_includes out, JSON.parse(res.body).fetch('token')
  end
end
