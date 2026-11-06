# Commit notifications for long polling (GET /manifest?wait=N), one feed per vault. A dev reload replaces this class:
# the reloader closes every feed first, so no poll waits on a stale condition variable (config.ru).
# A notify comes only from commits of this process; another process's (MCP running apart) is seen by the re-check every
# RECHECK seconds a wait does.
class ChangeFeed
  MAX_WAIT = 60 # s; a client asking for more gets this
  RECHECK = 2 # s: the latest a waiting poll hears of another process's commit
  REGISTRY = Mutex.new
  @feeds = []
  @closed = false

  # Server shutting down / dev reload: wake every waiting poll, and none waits again — feeds created later included
  # (Puma's graceful stop would sit out their waits). Not from a trap handler directly: it takes a mutex
  def self.close_all
    REGISTRY.synchronize do
      @closed = true
      @feeds.dup
    end.each(&:close)
  end

  def self.register(feed)
    REGISTRY.synchronize do
      @feeds << feed
      feed.close if @closed
    end
  end

  def initialize
    @lock = Mutex.new
    @changed = ConditionVariable.new
    @closed = false
    self.class.register(self)
  end

  # After every commit
  def notify
    @lock.synchronize { @changed.broadcast }
  end

  def close
    @lock.synchronize do
      @closed = true
      @changed.broadcast
    end
  end

  # Blocks until the version the block returns differs from known, or timeout seconds pass. The check and the wait
  # happen under the lock, so a commit's notify can't slip in between them. Checked again every RECHECK seconds
  def wait(known, timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.clamp(0, MAX_WAIT)
    @lock.synchronize do
      loop do
        return if @closed || yield != known

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if remaining <= 0

        @changed.wait(@lock, [remaining, RECHECK].min)
      end
    end
  end
end
