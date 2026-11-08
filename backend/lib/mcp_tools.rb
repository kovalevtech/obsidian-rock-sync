require 'json'

# The MCP tools a scoped token gets (McpEndpoint serves them; the `mcp` gem does the JSON-RPC). What a token may list,
# read, write or delete is its grants' (Grants, decided by Access), in one vault or several; its name is the commits'
# author (`<name>@token`). Anything outside the grants looks like what isn't there: not found, no hint either way.
# Write results never carry file content. Refusals and bad input are tool errors (isError) with a message Claude can
# act on.
module McpTools
  # The caller: a scoped token and its grants
  Token = Data.define(:id, :name, :grants) do
    def vaults = grants.map(&:vault).uniq
  end

  # A tool error's message
  class Refused < StandardError; end

  RATE = RateLimit.new(limit: 60, period: 60) # tool calls per token
  READ_MAX = 1024 * 1024 # bytes: the most text read_file returns (it goes into Claude's context: already ~250k tokens)
  # Bytes: the most an image may be — the API takes 10 MB per image, base64-encoded. Not READ_MAX: an image costs
  # Claude at most a few thousand tokens whatever its size (scaled down to its resolution limit)
  IMAGE_MAX = 10 * 1024 * 1024 / 4 * 3
  # Images read_file returns as MCP image content (Claude sees them), known by their first bytes; WebP: see image_type
  IMAGES = { "\x89PNG\r\n\x1A\n".b => 'image/png', "\xFF\xD8\xFF".b => 'image/jpeg', 'GIF87a'.b => 'image/gif',
             'GIF89a'.b => 'image/gif' }.freeze
  ETAG = { type: 'string', pattern: '^[0-9a-f]{40}$' }.freeze
  VAULT = { type: 'string', description: 'Vault name, from list_access; needed only when your grants are in several vaults' }.freeze

  # Exceptions inside a tool become a JSON-RPC "Internal error" (the gem's); the log gets what it was
  CONFIGURATION = MCP::Configuration.new(
    exception_reporter: ->(e, _context) { warn "vault-sync: MCP tool failed: #{e.class}: #{e.message}" }
  )

  # One per request: no sessions, the token is the request's
  def self.server(token)
    MCP::Server.new(name: 'vault-sync', version: '1', instructions: instructions(token), tools: TOOLS,
                    server_context: { token: }, capabilities: { tools: {} }, configuration: CONFIGURATION)
  end

  # Told at initialize: where Claude may read and write and what for, without a call to list_access. A purpose follows
  # its grant, its further lines indented under it
  def self.instructions(token)
    grants = token.grants.map do |g|
      purpose = g.purpose.empty? ? '' : " — #{g.purpose.gsub("\n", "\n  ")}"
      "- #{g.vault}: `#{label(g.folder)}` (#{g.mode})#{purpose}"
    end
    <<~TEXT
      Reads and writes notes (Markdown) in the user's Obsidian vaults, inside the folders granted to you (`/` = the whole vault; subfolders included; `r` = list and read, `w` = create and append, `rw` = also replace and delete; where grants overlap, their modes add up):
      #{grants.any? ? grants.join("\n") : '- none: nothing can be read or written yet'}
      The text after a grant is the user's own note on what that folder is for and how to use it: follow it. list_access returns the same list. Paths are vault paths inside these folders, like `Inbox/Idea.md`. #{token.vaults.size > 1 ? 'Your grants are in several vaults: name one in every tool call (`vault`).' : 'Tools take a `vault` argument; with grants in one vault it can be left out.'}
      Use list_folder / read_file to look around, append_file to add to a note ("add this to …"), write_file without `base` to create a new one, with `base` (the etag from read_file) to replace one, delete_file with `base` to remove one. Every file comes with its last commit's author: `device` = the user edited it on a device, `token` = a connector like you wrote it.
    TEXT
  end

  def self.label(folder) = folder.empty? ? '/' : folder

  def self.ok(result) = MCP::Tool::Response.new([{ type: 'text', text: JSON.generate(result) }])
  def self.error(message) = MCP::Tool::Response.new([{ type: 'text', text: message }], error: true)

  # Every tool call: the rate limit, then the size of what it writes (before the vault is touched), then the tool: its
  # result as JSON text, or a Response of its own (read_file's image).
  # texts: { argument name => text }
  def self.call(server_context, texts = {})
    token = server_context[:token]
    return error('Too many calls: at most 60 a minute. Wait a minute, then try again.') unless RATE.allow?(token.id)

    texts.each do |name, text|
      next if text.bytesize <= Config.mcp_max_write

      return error("`#{name}` is #{text.bytesize} bytes, at most #{Config.mcp_max_write} per call: write a first part, " \
                   'then append_file the rest.')
    end
    result = yield(token)
    result.is_a?(MCP::Tool::Response) ? result : ok(result)
  rescue Refused => e
    error(e.message)
  end

  # write_file's base64 content → its bytes: whitespace dropped (line breaks), then strict. The size is known from the
  # length, so a too big one is refused undecoded
  def self.decode64(content)
    data = content.delete(" \t\r\n")
    size = (data.size / 4 * 3) - data[-2..].to_s.count('=')
    if size > Config.mcp_max_write
      raise Refused, "`content` is #{size} bytes, at most #{Config.mcp_max_write} per call: too big to write here."
    end

    data.unpack1('m0')
  rescue ArgumentError
    raise Refused, '`content` isn\'t valid base64 (`encoding: base64`): nothing written.'
  end

  # 'image/…' when the bytes are an image read_file shows, else nil
  def self.image_type(bytes)
    head = bytes.byteslice(0, 12).b
    return 'image/webp' if head.start_with?('RIFF') && head.byteslice(8, 4) == 'WEBP'

    IMAGES.find { |magic, _| head.start_with?(magic) }&.last
  end

  # The vault a call means: the one named (one the token has grants in), else the token's only one
  def self.vault(token, name)
    vaults = token.vaults
    raise Refused, 'Nothing is granted to you: nothing can be read or written.' if vaults.empty?

    name ||= vaults.first if vaults.one?
    raise Refused, "Name the vault (`vault`): one of #{vaults.map { "`#{_1}`" }.join(', ')}." unless name
    raise Refused, "Vault `#{name}` not found." unless vaults.include?(name)

    Vault.find(name) or raise Refused, "Vault `#{name}` isn't available right now."
  end

  # The one answer for a path that isn't there, or isn't Claude's to see: the same either way
  def self.not_found(vault, rel) = Refused.new("`#{label(rel)}` not found in #{vault.name}.")

  # A vault-relative path from what Claude sent (slashes around it tolerated); refused by Vault::Path → Refused: a
  # hidden one as not found (MCP never sees hidden paths), the rest as a bad path
  def self.relative(vault, path)
    rel = path.gsub(%r{\A/+|/+\z}, '')
    vault.normalize(rel)
  rescue Vault::Path::Hidden
    raise not_found(vault, rel)
  rescue Vault::Path::BadPath
    raise Refused, "`#{path}` isn't a path inside the vault: use one like `Inbox/Note.md`."
  end

  # → [vault, normalized path, .md added when the name has no extension] on which the token has every one of modes
  # (:r, :w); else not found
  def self.file(token, vault_name, path, *modes)
    vault = vault(token, vault_name)
    rel = relative(vault, path)
    rel = relative(vault, "#{rel}.md") if File.extname(rel).empty? # checked again: it may be too long now
    raise not_found(vault, rel) unless modes.all? { Access.allowed?(token.grants, vault.name, rel, _1) }
    raise Refused, "`#{rel}` is a folder: name a file inside it." if File.directory?(vault.file(rel))

    [vault, rel]
  end

  def self.author(token) = Vault::Author.new(name: token.name, kind: 'token', client: Vault::Author::MCP_CLIENT)

  # { modified_at, author } of a file from its last commit (Git#last_commits)
  def self.commit_info(commit)
    return { modified_at: nil, author: nil } unless commit

    { modified_at: commit[:time].iso8601, author: Vault::Author.of(**commit.slice(:name, :email, :client)) }
  end

  LIST_ACCESS = MCP::Tool.define(
    name: 'list_access',
    description: <<~TEXT,
      List the folders granted to you, per vault, with their modes and purposes: `r` = you may list and read files there, `w` = create and append files, `rw` = also replace and delete; subfolders included, and where grants overlap their modes add up. `purpose` (when there is one) is the user's note on what the folder is for and how to use it: follow it. The server instructions carry the same list: call this when unsure where to read or write, or after a not-found error.
      Result: JSON `[{"vault", "folder", "mode", "purpose"?}]`.
    TEXT
    input_schema: { properties: {}, additionalProperties: false },
    annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false }
  ) do |server_context:|
    McpTools.call(server_context) do |token|
      token.grants.map do |grant|
        { vault: grant.vault, folder: McpTools.label(grant.folder), mode: grant.mode,
          **(grant.purpose.empty? ? {} : { purpose: grant.purpose }) }
      end
    end
  end

  LIST_FOLDER = MCP::Tool.define(
    name: 'list_folder',
    description: <<~TEXT,
      List the files in a folder you may read: subfolders included unless `recursive` is false, only what your readable grants cover — from a folder above them (the vault root, say) just their parts. Files only, no folders.
      Result: JSON `[{"path", "etag", "size", "modified_at", "author": {"kind", "name"}}]`, sorted by path. modified_at and author = the last commit touching the file; author kind `device` = the user edited it on a device, `token` = a connector (like you), `unknown` = the server.
    TEXT
    input_schema: {
      properties: {
        path: { type: 'string', description: 'Vault folder, e.g. `Projects/Notes`; omit (or `/`) for the vault root' },
        recursive: { type: 'boolean', description: 'Subfolders too (default true)' },
        vault: VAULT
      },
      additionalProperties: false
    },
    annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false }
  ) do |server_context:, path: nil, recursive: true, vault: nil|
    McpTools.call(server_context) do |token|
      vault = McpTools.vault(token, vault)
      under = path.to_s.delete('/').empty? ? '' : McpTools.relative(vault, path)
      _, files = BuildManifest.call(vault)
      # A folder that's there (any file under it, its .keep at least), readable or holding a readable one
      there = under.empty? || files.each_key.any? { _1.start_with?("#{under}/") }
      readable = Access.folders(token.grants, vault.name, :r)
      unless there && !Access.hidden?(under) && readable.any? { Access.holds?(_1, under) || Access.holds?(under, _1) }
        raise McpTools.not_found(vault, under)
      end

      listed = files.select do |file, _|
        Access.holds?(under, file) && file != under && Access.allowed?(token.grants, vault.name, file, :r) &&
          (recursive || File.dirname(file) == (under.empty? ? '.' : under))
      end
      commits = vault.git.last_commits(listed.keys, under:)
      listed.sort.map do |file, (etag, size)|
        { path: file, etag:, size:, **McpTools.commit_info(commits[file]) }
      end
    end
  end

  READ_FILE = MCP::Tool.define(
    name: 'read_file',
    description: <<~TEXT,
      Read a file in a folder you may read: a text file (a note), or an image (PNG, JPEG, GIF, WebP; up to 7.5 MB), which you then see. Without an extension `.md` is added.
      Result: JSON `{"path", "etag", "content", "modified_at", "author": {"kind", "name"}}` (the last commit touching it, as for list_folder); for an image `size` and `mime_type` instead of `content`, then the image. Pass the etag as `base` to write_file / delete_file. Other binary files can't be read: the error gives their size and etag.
    TEXT
    input_schema: {
      properties: {
        path: { type: 'string', description: 'Vault path, e.g. `Inbox/Idea.md`' },
        vault: VAULT
      },
      required: %w[path],
      additionalProperties: false
    },
    annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false }
  ) do |path:, server_context:, vault: nil|
    McpTools.call(server_context) do |token|
      vault, rel = McpTools.file(token, vault, path, :r)
      etag, content, = begin
        ReadFile.call(vault, rel)
      rescue Vault::NotFound
        raise McpTools.not_found(vault, rel)
      end
      size = content.bytesize
      if (mime_type = McpTools.image_type(content))
        raise Refused, "`#{rel}` is an image of #{size} bytes (etag #{etag}), at most #{IMAGE_MAX} can be read." if size > IMAGE_MAX
      else
        raise Refused, "`#{rel}` is #{size} bytes (etag #{etag}), at most #{READ_MAX} can be read." if size > READ_MAX

        text = content.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding? && !text.include?("\0")
          raise Refused, "`#{rel}` is binary (#{size} bytes, etag #{etag}): only text files and images (PNG, JPEG, " \
                         'GIF, WebP) can be read.'
        end
      end

      commit = McpTools.commit_info(vault.git.last_commits([rel], under: rel)[rel])
      next { path: rel, etag:, content: text, **commit } unless mime_type

      info = JSON.generate({ path: rel, etag:, size:, mime_type:, **commit })
      MCP::Tool::Response.new([{ type: 'text', text: info },
                               { type: 'image', data: [content].pack('m0'), mimeType: mime_type }])
    end
  end

  WRITE_FILE = MCP::Tool.define(
    name: 'write_file',
    description: <<~TEXT,
      Create a new file in the user's Obsidian vault — or replace one you read.
      Without `base`: creates the file only if nothing is at `path` yet. If something is, the result is `exists` and nothing is written: pick another name, read_file it, or append_file to it.
      With `base`: replaces the file, only if it is still that version. Pass only an `etag` from read_file / list_folder or an earlier result for this same path — never guess one. If the file changed since (or is gone), the result is `stale` and nothing is written: read_file it again (`stale` carries the current etag where you may read), or tell the user. Nothing is merged.
      Path: inside a folder you may write to (see list_access), with a readable file name, like `Inbox/Call with Anna 2023-03-14.md`. Subfolders are created as needed. Without an extension `.md` is added. Content: the whole file, Markdown for notes. A binary file (an image, a PDF): its bytes as base64 in `content`, with `encoding: base64` and the file's extension in `path`.
      Result: JSON `{"status", "path", "etag"}` — never the file's content. status: written, unchanged (that exact content was there), exists, stale; etag after written / unchanged, and after stale where you may read.
    TEXT
    input_schema: {
      properties: {
        path: { type: 'string', description: 'Vault path, e.g. `Inbox/Idea.md`' },
        content: { type: 'string', description: 'The whole file: text, or base64 with `encoding: base64`' },
        encoding: { type: 'string', enum: %w[text base64],
                    description: '`base64` for a binary file: `content` is its bytes as plain base64 (no `data:` prefix); default `text`' },
        base: ETAG.merge(description: 'The etag of the version you are replacing, from read_file or an earlier result'),
        vault: VAULT
      },
      required: %w[path content],
      additionalProperties: false
    },
    annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: false, open_world_hint: false }
  ) do |path:, content:, server_context:, encoding: 'text', base: nil, vault: nil|
    binary = encoding == 'base64'
    McpTools.call(server_context, binary ? {} : { content: }) do |token|
      content = McpTools.decode64(content) if binary # its size checked first: before the vault, as a text's
      vault, rel = McpTools.file(token, vault, path, :w)
      # mergeable: false — a stale base is stale, never merged
      status, etag = WriteFile.call(vault, rel, content, if_match: base, if_none_match: base ? nil : '*',
                                                         author: McpTools.author(token), keeps: true)
      case status
      when :written, :unchanged then { status:, path: rel, etag: }
      when :stale
        next { status: :exists, path: rel } unless base

        # The current version's etag only where Claude may read it: no blind overwrite of a file it can't see
        readable = etag && Access.allowed?(token.grants, vault.name, rel, :r)
        { status: :stale, path: rel, **(readable ? { etag: } : {}) }
      end
    end
  end

  APPEND_FILE = MCP::Tool.define(
    name: 'append_file',
    description: <<~TEXT,
      Add text to the end of a file in the user's Obsidian vault — for "add this to …", "append to …", "put this in my …" (a log, a list, an inbox note). The text starts on a new line after what's there; nothing already there changes, no etag needed, no conflicts. A missing file is created with the text. Start the text with a blank line or a heading if it should stand apart.
      Path: as for write_file; without an extension `.md` is added.
      Result: JSON `{"status", "path", "etag"}` — never the file's content. status: appended, created, unchanged (empty text).
    TEXT
    input_schema: {
      properties: {
        path: { type: 'string', description: 'Vault path, e.g. `Inbox/Reading list.md`' },
        text: { type: 'string', description: 'What to add at the end' },
        vault: VAULT
      },
      required: %w[path text],
      additionalProperties: false
    },
    annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false }
  ) do |path:, text:, server_context:, vault: nil|
    McpTools.call(server_context, text:) do |token|
      vault, rel = McpTools.file(token, vault, path, :w)
      status, etag = AppendFile.call(vault, rel, text, author: McpTools.author(token), keeps: true)
      raise Refused, "`#{rel}` isn't a text file: nothing appended." if status == :not_text

      { status:, path: rel, etag: }
    end
  end

  DELETE_FILE = MCP::Tool.define(
    name: 'delete_file',
    description: <<~TEXT,
      Delete a file in a folder you may read and write (`rw`), if it is still the version you saw.
      `base`: its etag from read_file / list_folder. If the file changed since, the result is `stale` with the current etag and nothing is deleted: read_file it again, or tell the user. Already gone: `gone`, nothing to do. Without an extension `.md` is added.
      Result: JSON `{"status", "path", "etag"}`. status: deleted, gone, stale (etag only then).
    TEXT
    input_schema: {
      properties: {
        path: { type: 'string', description: 'Vault path, e.g. `Inbox/Done.md`' },
        base: ETAG.merge(description: 'The etag of the version you are deleting'),
        vault: VAULT
      },
      required: %w[path base],
      additionalProperties: false
    },
    annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false }
  ) do |path:, base:, server_context:, vault: nil|
    McpTools.call(server_context) do |token|
      vault, rel = McpTools.file(token, vault, path, :r, :w)
      status, etag = DeleteFile.call(vault, rel, if_match: base, author: McpTools.author(token))
      status == :stale ? { status:, path: rel, etag: } : { status:, path: rel }
    end
  end

  TOOLS = [LIST_ACCESS, LIST_FOLDER, READ_FILE, WRITE_FILE, APPEND_FILE, DELETE_FILE].freeze
end
