# The request path as the client sent it must be the one a proxy's rules see and the one the apps route: one reading
# only. In front of everything (config.ru), so it covers every app, /health and the request log. A request whose raw
# path isn't canonical gets 400 with an empty body and one log line (the path without its query), and goes no further:
# - not origin-form: the request target doesn't start with `/` (absolute-form `GET http://host/x` — Puma routes its
#   path —, `OPTIONS *`)
# - an empty segment (`//`, a leading `//` too; one trailing `/` is fine), a `.` or `..` segment
# - `\`, or an encoded `/`, `\` or `.` (`%2f`, `%5c`, `%2e`, any case)
# - malformed percent-encoding (`%` without two hex digits)
# - a control character, raw or encoded (`%00`, `%0a`, `%7f`, `%c2%85`)
# Why: Rack::URLMap matches the raw path (`/+admin`), then rack-protection's PathTraversal decodes `%2f` / `%2e` / `%5c`
# and resolves dot segments inside the app, while a proxy (Cloudflare) resolves them before its rules and forwards the
# raw path: `/admin/../files/a%2f..%2f..%2flogin` read `/files/…` to the proxy and `/login` to Admin. A real client
# never sends any of it: encodeURIComponent per segment (the plugin's encodePath) leaves `.` as is and sends `%` as `%25`
# (decoded once here, `%252f` is the text `%2f`); only names Obsidian refuses (`\`, control characters) or never syncs
# (`.`, `..`: hidden) would.
class CanonicalPath
  ENCODED_STRUCTURE = /%(?:2f|5c|2e)/i
  MALFORMED = /%(?![0-9a-f]{2})/i
  CONTROL = /\p{Cc}/

  def self.canonical?(path)
    return false unless path.start_with?('/') && !path.include?('\\')
    return false if ENCODED_STRUCTURE.match?(path) || MALFORMED.match?(path)

    segments = path[1..].split('/', -1)
    segments.pop if segments.last == ''
    return false if segments.any? { |s| s.empty? || s == '.' || s == '..' }

    decoded = path.b.gsub(/%(\h\h)/) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8).scrub
    !CONTROL.match?(decoded)
  end

  def initialize(app)
    @app = app
  end

  def call(env)
    # Puma: REQUEST_URI = the request target as sent; PATH_INFO = what routing reads (for absolute-form, its path)
    target = env['REQUEST_URI']&.split('?', 2)&.first
    return @app.call(env) if [env['PATH_INFO'].to_s, target].compact.all? { self.class.canonical?(_1) }

    puts "vault-sync: refused a non-canonical path: #{env['REQUEST_METHOD']} #{(target || env['PATH_INFO']).to_s.inspect}"
    [400, {}, []]
  end
end
