# Long polls (GET /manifest?wait=N) waiting at once: each holds a Puma thread, and keeps it after its client hung up
# (nothing tells the thread). One per token: a token is one device in one vault, so its older poll is one left behind
# (a window closed or reloaded — the desktop app finishes its requests anyway —, a stop() + start(), a dropped
# connection) and a new one ends it (it answers as after its wait: 304) instead of being refused. Capped for the
# process, so plain requests (/health included) always find a thread. In memory, one process
module PollSlots
  SPARE_THREADS = 4 # Puma threads never held by polls
  LOCK = Mutex.new
  @held = {} # token id → its Poll

  # A waiting poll; ChangeFeed#wait returns once it's ended
  class Poll
    def initialize(feed)
      @feed = feed
      @ended = false
    end

    def ended? = @ended

    # Set before the feed's broadcast: a wait checks it under the feed's lock, so it either sees it or is woken
    def end!
      @ended = true
      @feed.notify
    end
  end

  def self.limit = Config.max_threads - SPARE_THREADS

  # Runs the block with the token's Poll (waiting on feed) and returns true; false (block not run) when the process'
  # cap is reached. The token's older poll is ended, not counted
  def self.hold(token_id, feed)
    poll = Poll.new(feed)
    older = LOCK.synchronize do
      older = @held[token_id]
      return false if !older && @held.size >= limit

      @held[token_id] = poll
      older
    end
    older&.end!
    begin
      yield poll
    ensure
      LOCK.synchronize { @held.delete(token_id) if @held[token_id].equal?(poll) }
    end
    true
  end

  # Polls waiting now (tests)
  def self.count = LOCK.synchronize { @held.size }
end
