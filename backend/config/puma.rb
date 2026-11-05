# Loaded by `rackup` in dev, by `puma` in the image (Dockerfile). Every client waiting in a long poll
# (GET /manifest?wait=N) holds a thread for up to a minute: room for several devices plus their normal requests.
require_relative '../config'
threads 0, Config.max_threads # the DB pool matches it

# Container: every interface (compose decides what's published). Dev keeps rackup's localhost
port Integer(ENV.fetch('PORT', 9292)), '0.0.0.0' if ENV['RACK_ENV'] == 'production'

# TERM (docker stop) → graceful stop, then exit 0. Puma's default re-raises SIGTERM: as PID 1 that ends in exit 1,
# which reads like a crash
raise_exception_on_sigterm false

# Bodies over the limit: 413 from Content-Length, before Puma buffers them (app.rb checks the same for other servers)
http_content_length_limit Config.max_file_size

# Ctrl+C / TERM: Puma stops gracefully, finishing requests first — long polls would hold that up to a minute. Wake them
# first, then Puma's own handler. In a thread: a trap handler can't take a mutex
after_booted do
  %w[INT TERM].each do |signal|
    previous = Signal.trap(signal) do
      Thread.new { ChangeFeed.close_all }.join
      previous.call if previous.respond_to?(:call)
    end
  end
end
