# Form and multipart bodies: App and McpEndpoint read none (the plugin sends text/markdown or application/octet-stream,
# /pair and MCP JSON). Sinatra would parse one into params before any filter, auth included: a chunked form PUT without
# a token was a 500 from Rack's query parser, and Rack's multipart parser has had memory-exhaustion bugs. So Rack is
# told up front that no request holds a form (`ignore`: nothing parsed, the body left to the route), and a request
# that sends one is refused after auth (`sent?` → 415)
module FormBody
  TYPES = %r{\A(application/x-www-form-urlencoded|multipart/)}i

  def self.ignore(env) = env[Rack::RACK_REQUEST_FORM_PAIRS] = []

  # Only with a body: a form type on a bodiless request is harmless (rack-test's default, maybe some HTTP stacks' for
  # DELETE / POST). Chunked: Puma has de-chunked it and set Content-Length; other servers keep Transfer-Encoding
  def self.sent?(request)
    request.media_type.to_s.match?(TYPES) &&
      (request.content_length.to_i.positive? || request.env.key?('HTTP_TRANSFER_ENCODING'))
  end
end
