require_relative 'environment'

# MCP for Claude (a claude.ai custom connector): POST /mcp, Streamable HTTP without sessions — every POST answered with
# plain JSON, no SSE. The token (a scoped one, Devices) comes as `Authorization: Bearer <token>` (the connector's
# request headers); the path carries nothing secret. Outside App's Basic auth. The tools are McpTools'. Not reloaded by
# Zeitwerk (like app.rb).
class McpEndpoint < Sinatra::Base
  BEARER = /\ABearer +(\S+)\z/i

  # Bytes of a request body: what one call may write (MCP_MAX_WRITE) twice over — JSON's escapes, base64's third — and
  # the rest of the JSON-RPC, never over MAX_FILE_SIZE. Refused unread: the gem parses the whole body before a tool
  # sees its size
  def self.max_body = [(Config.mcp_max_write * 2) + (64 * 1024), Config.max_file_size].min

  set :show_exceptions, false
  set :static, false # public/ (Admin's stylesheet) would be served before the token is looked at
  # Its own auth (the header): no browser session to protect, and claude.ai's requests may name another Origin
  set :protection, except: :http_origin

  # Sinatra parses a form body into params before any filter, the token's included: here none is, ever (FormBody)
  def call!(env)
    FormBody.ignore(env)
    super
  end

  # /mcp only (anything below it is the 404 of any unknown path), then the token, then POST only: no SSE stream to
  # open (GET), no session to end (DELETE). Why a token failed stays unsaid, in the log too
  before do
    halt 404 unless ['', '/'].include?(request.path_info)

    token, = Devices.authenticate(env['HTTP_AUTHORIZATION'].to_s[BEARER, 1], kind: 'scoped')
    unless token
      env['vault_sync.auth'] = 'mcp auth failed'
      halt 401, { 'content-type' => 'application/json', 'www-authenticate' => 'Bearer' }, '{"error":"unauthorized"}'
    end
    Devices.touch(token.id)
    env['vault_sync.auth'] = "mcp token=#{token.name}"
    @token = McpTools::Token.new(id: token.id, name: token.name, grants: Grants.of(token.id))
    halt 405, { 'allow' => 'POST' }, '' unless request.post?
    halt 413 if request.content_length.to_i > McpEndpoint.max_body
    halt 415 if FormBody.sent?(request)
  end

  # JSON-RPC: initialize, notifications/initialized, tools/list, tools/call. A notification has no answer: 202
  post %r{/?} do
    body = request.body.read(McpEndpoint.max_body + 1).to_s # chunked: no Content-Length to go by
    halt 413 if body.bytesize > McpEndpoint.max_body

    response = McpTools.server(@token).handle_json(body)
    next 202 unless response

    content_type :json
    response
  end
end
