# At most `limit` calls per key within the last `period` seconds, in memory (one process; a restart forgets)
class RateLimit
  def initialize(limit:, period:)
    @limit = limit
    @period = period
    @calls = Hash.new { |h, k| h[k] = [] }
    @lock = Mutex.new
  end

  # Counts the call if it's allowed
  def allow?(key, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    @lock.synchronize do
      calls = @calls[key]
      calls.shift while calls.any? && calls.first <= now - @period
      return false if calls.size >= @limit

      calls << now
      true
    end
  end

  # Tests: every key starts over
  def reset = @lock.synchronize { @calls.clear }
end
