require 'monitor'

# An exclusive lock across threads and processes: a Monitor within the process (reentrant: the holder may take it
# again), flock on a file across processes (sync, mcp and admin may run as processes of their own on the same data).
# The file is created if missing and never removed; the flock goes with the descriptor, so a crash releases it.
class FileLock
  def initialize(path)
    @path = path
    @monitor = Monitor.new
    @depth = 0
  end

  def synchronize
    @monitor.synchronize do
      if @depth.zero?
        file = File.open(@path, File::RDWR | File::CREAT, 0o644)
        begin
          file.flock(File::LOCK_EX) # waits without holding up the process's other threads
        rescue Exception # an interrupted wait too: no descriptor left open
          file.close
          raise
        end
        @file = file
      end
      @depth += 1
      begin
        yield
      ensure
        @depth -= 1
        if @depth.zero?
          @file.close # releases the flock
          @file = nil
        end
      end
    end
  end
end
