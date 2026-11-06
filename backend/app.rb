require_relative 'environment'
require 'json'
require 'time' # Time#httpdate
require 'uri'

class App < Sinatra::Base
  set :show_exceptions, false

  # Matched by name: Zeitwerk reload replaces the class objects, class-keyed handlers stop matching
  error StandardError do
    e = env['sinatra.error']
    case e.class.name
    when 'Vault::Path::BadPath', 'Vault::Path::Hidden' then [400, e.message]
    when 'Vault::NotFound', 'Sinatra::NotFound' then 404 # the latter: no such route
    else 500
    end
  end

  # Paths answered without credentials (exact path_info). Everything else needs them, unknown routes included
  PUBLIC = ['/health', '/pair'].freeze
  # Paths that need the token only: the vault part of Basic is ignored (may be empty). Everything else needs a vault
  # the token may use
  DEVICE_ONLY = ['/vaults', '/token'].freeze
  UNAUTHORIZED = JSON.generate(error: 'unauthorized')
  PAIR_MAX_BODY = 1024 # bytes read of POST /pair's body: no credentials, so not whatever anyone sends
  # GET /manifest's ETag before a vault's first commit (no HEAD yet): polls wait past it like past a version
  NO_COMMITS = 'no-commits'
  # A long poll over PollSlots' caps: 429 + Retry-After (s; the plugin backs off 5 s on any failure anyway)
  POLLS_REFUSED = JSON.generate(error: 'too many polls')
  POLL_RETRY_AFTER = '5'

  # Sinatra parses a form body into params before any filter, auth included: here none is, ever (FormBody)
  def call!(env)
    FormBody.ignore(env)
    super
  end

  # Auth first: nobody learns the size limit without a token. Over the limit: refused before the body is read. Puma
  # does the same (config/puma.rb), without even buffering it. Then form bodies: refused, unread
  before do
    # An old version from a client's HTTP cache looks synced: a file with a Last-Modified counts as fresh for a tenth of
    # its age there, no request made (Obsidian's requestUrl on desktop is Chromium's)
    cache_control :no_store
    unless PUBLIC.include?(request.path_info)
      DEVICE_ONLY.include?(request.path_info) ? authenticate_token! : authenticate!
    end
    halt 413 if request.content_length.to_i > Config.max_file_size
    halt 415 if FormBody.sent?(request)
  end

  helpers do
    # The only place reading Authorization: Basic base64("<vault>:<token>") → @device, @vault. Every failure is the same
    # 401: no WWW-Authenticate (a browser would ask for a login), nothing about which vault was expected, nothing about
    # a revoked token. The reason goes to the log only (env['vault_sync.auth'], config.ru)
    def authenticate!
      vault_name = authenticate_device!
      vault_header!(vault_name)
      @device.vault == vault_name or unauthorized!("vault #{vault_name.inspect} not allowed for #{@device.name}")
      vault_allowed!(vault_name)
      @vault = Vault.find(vault_name) or unauthorized!("vault #{vault_name.inspect} missing in VAULTS_DIR")
      env['vault_sync.auth'] = "device=#{@device.name} vault=#{@vault.name}"
    end

    # DEVICE_ONLY routes: the token alone, Basic's vault part ignored. X-Rock-Sync-Vault, when sent, still has to name
    # the token's vault: else a proxy letting one vault through would let any token reach these
    def authenticate_token!
      authenticate_device!
      vault_header!(@device.vault)
      vault_allowed!(@device.vault)
    end

    # ALLOWED_VAULTS: a vault this process doesn't serve is refused like any other, its token too (DEVICE_ONLY routes)
    def vault_allowed!(vault_name)
      Config.vault_allowed?(vault_name) or unauthorized!("vault #{vault_name.inspect} not allowed in this process")
    end

    # X-Rock-Sync-Vault: the vault in the clear, for a proxy in front (Cloudflare) to filter on; it must not lie.
    # Absent: clients from before, or not through that proxy
    def vault_header!(vault_name)
      header = env['HTTP_X_ROCK_SYNC_VAULT']
      unauthorized!('vault header mismatch') if header && header != vault_name
    end

    # The token alone → @device; returns the vault part of the header (unchecked)
    def authenticate_device!
      scheme, encoded = env['HTTP_AUTHORIZATION'].to_s.split(' ', 2)
      vault_name, secret = (encoded.to_s.unpack1('m0') rescue '').split(':', 2) # strict base64
      unauthorized!('no Basic credentials') unless scheme&.casecmp?('basic') && secret

      device, failure = Devices.authenticate(secret)
      unauthorized!("#{failure} token") unless device
      @device = device
      Devices.touch(device.id)
      env['vault_sync.auth'] = "device=#{device.name}"
      vault_name
    end

    def unauthorized!(reason)
      env['vault_sync.auth'] = "unauthorized: #{reason}"
      halt 401, { 'content-type' => 'application/json' }, UNAUTHORIZED
    end

    # Commit author: the device's name; the client's software as a trailer
    def author = Vault::Author.new(name: @device.name, kind: 'device', client: env['HTTP_X_ROCK_SYNC_CLIENT'])

    # Merged only when the client sent text (the plugin: text/markdown for notes, application/octet-stream for the rest)
    def mergeable? = request.media_type.to_s.start_with?('text/')

    # A file version: ETag = blob hash (unquoted, as the client compares it), Last-Modified = its last commit
    def version_headers(hash, modified_at = nil)
      headers 'ETag' => hash if hash
      headers 'Last-Modified' => modified_at.httpdate if modified_at
    end
  end

  # Liveness for Docker / the homelab: public, says nothing about vaults or tokens
  get '/health' do
    content_type 'text/plain'
    'ok'
  end

  # A one-time code from the admin panel + this device's name → its token (new, or a Reconnect's new secret), the only
  # time it's shown, with its vault and its name (as sent, taken or not). No credentials: the code is them. Wrong,
  # used or expired: the same 401
  post '/pair' do
    content_type :json
    form = JSON.parse(request.body.read(PAIR_MAX_BODY).to_s, symbolize_names: true) rescue nil
    halt 400, JSON.generate(error: 'bad request') unless form.is_a?(Hash)

    result, detail, token = Pairings.redeem(form[:code], form[:name])
    case result
    when :paired
      env['vault_sync.auth'] = "paired device=#{detail.name}"
      JSON.generate(token:, vault: detail.vault, name: detail.name)
    when :bad_name then halt 422, JSON.generate(error: detail)
    when :limited then halt 429, JSON.generate(error: 'too many attempts')
    else unauthorized!(detail == :not_allowed ? 'pairing refused: vault not allowed in this process' : 'pairing refused')
    end
  end

  # The token's vault, as a list (plugins from before codes picked from it). Basic with any vault part, "" too;
  # X-Rock-Sync-Vault, if sent, must be the token's vault
  get '/vaults' do
    content_type :json
    JSON.generate(vaults: [@device.vault].select { Vault.find(_1) })
  end

  # The plugin's Remove (or a connection replaced): the token revokes itself
  delete '/token' do
    Devices.revoke(@device.id)
    204
  end

  get '/files/*' do
    hash, content, modified_at = ReadFile.call(@vault, params['splat'].first)
    version_headers(hash, modified_at)
    halt 304 if request.env['HTTP_IF_NONE_MATCH'] == hash # client already has this version
    content_type 'application/octet-stream'
    content
  end

  put '/files/*' do
    result, hash, body, modified_at = WriteFile.call(
      @vault, params['splat'].first, request.body.read,
      if_match: request.env['HTTP_IF_MATCH'],
      if_none_match: request.env['HTTP_IF_NONE_MATCH'],
      mergeable: mergeable?, author:
    )
    version_headers(hash, modified_at)
    content_type 'application/octet-stream' if body
    case result
    when :written, :unchanged then 204
    when :merged then body # 200 + merged body: client must replace its local copy
    # Merged file with conflict markers; the client resolves it, then pushes with If-Match = this ETag
    when :conflict then [409, body]
    # Current server version, so the client can show it without another GET; none if the file is gone
    when :stale then body ? [412, body] : 412
    end
  end

  # If-Match: the version the client deleted. 204 also when already gone; edited elsewhere → 412 + current version
  delete '/files/*' do
    result, hash, body, modified_at = DeleteFile.call(@vault, params['splat'].first, if_match: request.env['HTTP_IF_MATCH'], author:)
    next 204 unless result == :stale

    version_headers(hash, modified_at)
    content_type 'application/octet-stream'
    [412, body]
  end

  # Rename: Destination = the new path inside the same vault, URL-encoded like the request path. 204 + ETag of the file at the new path;
  # 409 target taken, 404 source missing
  post '/move/*' do
    to = request.env['HTTP_DESTINATION'] or halt 400, 'Destination header required'
    result, hash = MoveFile.call(@vault, params['splat'].first, URI.decode_uri_component(to), author:)
    next 409 if result == :exists

    version_headers(hash)
    204
  end

  # Dry run of PUT's 3-way merge (If-Match = base, body = the client's version): 200 + clean text or 409 + text with
  # conflict markers, ETag = current server version. Nothing is written. 412 like PUT when there's nothing to merge.
  post '/merge/*' do
    result, hash, body, modified_at = MergeVersions.call(
      @vault, params['splat'].first, request.body.read, base: request.env['HTTP_IF_MATCH'], mergeable: mergeable?
    )
    version_headers(hash, modified_at)
    content_type 'application/octet-stream'
    status({ clean: 200, conflict: 409, stale: 412 }.fetch(result))
    body
  end

  # Long poll with ?wait=N (s, up to ChangeFeed::MAX_WAIT): answers once the vault's HEAD moves past the client's version
  # (If-None-Match, echoed as received) — or after N seconds, then usually 304. Without If-None-Match: right away.
  # Over PollSlots' caps (per token, per process): 429 at once, no wait. After a wait the credentials are checked
  # again: a token revoked (or Reconnected) meanwhile gets the 401, not one more manifest.
  # Format by ?v=: 1 → files { path => [hash, size] }; none (v0, clients from before sizes) → { path => hash }
  get '/manifest' do
    known = request.env['HTTP_IF_NONE_MATCH'].to_s.delete_prefix('W/').delete('"')
    if params['wait'] && !known.empty?
      waited = PollSlots.hold(@device.id) do
        @vault.feed.wait(known, params['wait'].to_i) { @vault.version || NO_COMMITS }
      end
      unless waited
        env['vault_sync.auth'] += ' (too many polls)'
        halt 429, { 'content-type' => 'application/json', 'retry-after' => POLL_RETRY_AFTER }, POLLS_REFUSED
      end
      authenticate!
    end
    version, files = BuildManifest.call(@vault)
    etag version || NO_COMMITS # halts with 304 when If-None-Match matches
    files = files.transform_values(&:first) unless params['v'] == '1'
    content_type :json
    JSON.generate(version:, files:)
  end
end
