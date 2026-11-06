# Long polls can't take every Puma thread (PollSlots): at most PER_TOKEN waiting per token and PollSlots.limit for the
# process, over that 429 at once; a slot is given back however the poll ends; a token revoked while its poll waited
# gets a 401, not the manifest
require_relative 'test_helper'
require 'json'

class LongPollTest < VaultTest
  include Rack::Test::Methods

  def app = App

  def setup
    super
    commit_file('a.md', "a\n")
    @etag = (get '/manifest', { 'v' => '1' }, auth(@token))['ETag']
  end

  def teardown
    assert_equal 0, PollSlots.count, 'a slot left held'
    super
  end

  def auth(token) = { 'HTTP_AUTHORIZATION' => "Basic #{["test:#{token}"].pack('m0')}" }

  # GET /manifest?wait= past the current version, in this thread → [response, seconds]
  def poll(token, wait: 10)
    session = Rack::Test::Session.new(App)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.get '/manifest', { 'v' => '1', 'wait' => wait.to_s }, { 'HTTP_IF_NONE_MATCH' => @etag, **auth(token) }
    [session.last_response, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  # Polls waiting in threads of their own, once they all hold their slot → their threads (value: [response, seconds])
  def waiting(*tokens, wait: 10)
    before = PollSlots.count
    threads = tokens.map { |token| Thread.new { poll(token, wait:) } }
    holding(before + tokens.size)
    threads
  end

  def holding(count)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until PollSlots.count == count || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_equal count, PollSlots.count
  end

  def assert_refused(res, took)
    assert_equal 429, res.status
    assert_equal '5', res['Retry-After']
    assert_equal({ 'error' => 'too many polls' }, JSON.parse(res.body))
    assert_operator took, :<, 1
  end

  def test_two_polls_per_token
    polls = waiting(@token, @token)
    assert_refused(*poll(@token))

    # The others aren't: the server, another token's poll, the same token's plain requests
    assert_equal 'ok', (get '/health').body
    assert_equal 200, (get '/manifest', { 'v' => '1' }, auth(@token)).status
    other = waiting(add_token('laptop', 'test'))

    commit_file('b.md', "b\n")
    (polls + other).each do |thread|
      res, = thread.value
      assert_equal 200, res.status
      assert_includes JSON.parse(res.body)['files'], 'b.md'
    end
  end

  # 12 with the default 16 threads: the 4 left answer everything else
  def test_polls_per_process
    assert_equal Config.max_threads - 4, PollSlots.limit
    tokens = (PollSlots.limit / PollSlots::PER_TOKEN).times.map { add_token("device-#{_1}", 'test') }
    polls = waiting(*tokens.flat_map { [_1, _1] })
    assert_refused(*poll(@token))
    assert_equal 'ok', (get '/health').body
    assert_equal 200, (get '/manifest', { 'v' => '1' }, auth(@token)).status

    commit_file('b.md', "b\n")
    polls.each { assert_equal 200, _1.value.first.status }
    @etag = %("#{@vault.version}")
    waiting(@token, @token, wait: 1).each { assert_equal 304, _1.value.first.status } # the slots are back
  end

  def test_a_poll_without_a_version_needs_no_slot
    polls = waiting(@token, @token)
    get '/manifest', { 'v' => '1', 'wait' => '10' }, auth(@token)
    assert_equal 200, last_response.status
    commit_file('b.md', "b\n")
    polls.each(&:join)
  end

  def test_slots_come_back_after_a_timeout
    waiting(@token, @token, wait: 1).each { assert_equal 304, _1.value.first.status }
    assert_equal 0, PollSlots.count
    waiting(@token, @token, wait: 1).each { assert_equal 304, _1.value.first.status }
  end

  def test_slots_come_back_after_an_error
    @vault.feed.define_singleton_method(:wait) { |*| raise 'boom' }
    2.times { assert_equal 500, poll(@token).first.status }
    assert_equal 0, PollSlots.count
    @vault.feed.singleton_class.remove_method(:wait)
    waiting(@token, @token, wait: 1).each(&:join)
  end

  # Shutdown (ChangeFeed.close_all closes every feed): the polls answer at once, their slots are back
  def test_slots_come_back_when_the_feed_closes
    polls = waiting(@token, @token)
    @vault.feed.close
    polls.each do |thread|
      res, took = thread.value
      assert_equal 304, res.status
      assert_operator took, :<, 5
    end
  end

  # Revoked, or its secret replaced (Reconnect), while the poll waited: no manifest for it
  def test_a_token_revoked_while_waiting_gets_the_401
    revoked = add_token('old-phone', 'test')
    rotated = add_token('tablet', 'test')
    polls = waiting(revoked, rotated)
    Devices.revoke(DB[:devices].where(name: 'old-phone').get(:id))
    Devices.rotate(DB[:devices].where(name: 'tablet').get(:id))
    commit_file('b.md', "b\n")
    polls.each do |thread|
      res, = thread.value
      assert_equal 401, res.status
      assert_equal '{"error":"unauthorized"}', res.body
    end
  end

  def test_a_token_revoked_while_waiting_gets_the_401_at_the_timeout_too
    polls = waiting(@token, wait: 1)
    Devices.revoke(DB[:devices].where(name: 'test-device').get(:id))
    assert_equal 401, polls.first.value.first.status
  end
end
