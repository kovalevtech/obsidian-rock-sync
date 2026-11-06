# Long polls (GET /manifest?wait=N) waiting at once: each holds a Puma thread, and keeps it after its client hung up
# (nothing tells the thread). Capped per token and for the process, so one token can't take every thread and plain
# requests (/health included) always find one. In memory, one process
module PollSlots
  PER_TOKEN = 2 # a device's poll, + one it left behind (a stop() + start(), a dropped connection)
  SPARE_THREADS = 4 # Puma threads never held by polls
  LOCK = Mutex.new
  @held = Hash.new(0) # token id → polls waiting

  def self.limit = Config.max_threads - SPARE_THREADS

  # Runs the block in a slot of the token's and returns true; false (block not run) when either cap is reached
  def self.hold(token_id)
    LOCK.synchronize do
      return false if @held[token_id] >= PER_TOKEN || @held.values.sum >= limit

      @held[token_id] += 1
    end
    begin
      yield
    ensure
      LOCK.synchronize { @held.delete(token_id) if (@held[token_id] -= 1).zero? }
    end
    true
  end

  # Polls waiting now (tests)
  def self.count = LOCK.synchronize { @held.values.sum }
end
