# MCP

The server has an [MCP](https://modelcontextprotocol.io) endpoint, so Claude can read and write notes in folders you choose: "save this to a note", "what's in my reading list". What Claude writes reaches your devices like any other device's commits. The plugin isn't involved.

## Connecting Claude

1. Add `mcp` to `ENABLED_APPS` on the server, such as `ENABLED_APPS=sync,mcp` ([Processes](deployment.md#processes)). It's off by default: `/mcp` doesn't exist.
2. In the [admin panel](admin.md#scoped-tokens), open **Scoped tokens** → **New token**, give it a name and at least one [grant](#grants).
3. The next page shows the URL and the token, once.
4. In claude.ai: **Settings → Connectors → Add custom connector**, with that URL and **No sign-in**. Under **Request headers**, add `Authorization` with the value `Bearer <token>`.

The server must be reachable from Anthropic's side, so it needs a public HTTPS address for `/mcp`. [Deployment](deployment.md#network) shows how to expose only that path. If `PUBLIC_URL` isn't that one, set `MCP_BASE_URL`, and the page will show the right URL.

Turning it off keeps the tokens and grants in the database, unusable; they work again when you turn it back on. To end a token for good, [revoke](admin.md#scoped-tokens) it.

## Grants

A scoped token reaches only what its grants name: any number of folders, in any number of vaults.

| Field | Meaning |
|---|---|
| Vault | Which vault |
| Folder | The folder and everything below it. Empty or `/` is the whole vault. `Notes` doesn't include `Notes2/` |
| Mode | `r`, `w` or `rw` |
| Purpose | Optional, up to 2000 characters: your instructions for the folder. Claude is told to follow them |

| Mode | Allows |
|---|---|
| `r` | `list_folder`, `read_file` |
| `w` | `write_file`, `append_file`. A file can be created; replacing one needs its current etag |
| `rw` | All of these, and `delete_file` |

**Overlapping grants add up,** so a nested grant can add rights but never take them away. A grant that adds nothing is refused when you save.

**Purposes do real work.** Claude sees them as soon as it connects:

```
default: `Claude/Inbox` (w) — Notes you asked me to save. One note per request, a readable name, no heading repeating the name.
```

**Renames:** when a folder is renamed through the sync API, the grants on it and below it follow, for all tokens. A grant can end up on a folder that's gone or redundant; it keeps working or does nothing, and the admin panel marks it.

**Never grantable:** hidden paths, meaning any segment starting with a dot: `.obsidian`, `.keep` files, and so on.

Whatever isn't granted looks exactly like what isn't there: "`X` not found in notes." A vault with no grant is "Vault `x` not found."

## Tools

Every tool takes `vault`, required only when the token's grants are in several vaults. Paths are relative to the vault. A path with no extension gets `.md`, except for `download_file`.

| Tool | Needs | Result |
|---|---|---|
| `list_access()` | any grant | `[{ vault, folder, mode, purpose? }]` |
| `list_folder(path?, recursive = true)` | `r` | `[{ path, etag, size, modified_at, author }]` |
| `read_file(path)` | `r` | `{ path, etag, content, modified_at, author }`; an image: `{ path, etag, size, mime_type, modified_at, author }` + the image |
| `write_file(path, content, encoding?, base?)` | `w` | `{ status, path, etag? }` |
| `append_file(path, text)` | `w` | `{ status, path, etag }` |
| `delete_file(path, base)` | `rw` | `{ status, path, etag? }` |
| `download_file(url, path, base?)` | `w` | `{ status, path, etag?, size, content_type }`; from [download hosts](#download_file) only |

- **`etag`** is the file's git blob hash.
- **`modified_at`** is the last commit touching the file, in UTC.
- **`author`** is `{ kind, name }` of that commit: `device` means you edited it on a device, `token` means a connector wrote it, `unknown` means the server did.

### `list_folder`

Lists files only, without folders, sorted, and only what `r` covers. `path` may be above the grants (the vault root by default), and then lists just the granted parts.

### `read_file`

Reads UTF-8 text with no NUL bytes, at most 1 MB. An image (PNG, JPEG, GIF or WebP, known by its bytes, not its name) up to 7.5 MB comes as MCP image content, so Claude sees it, after its JSON with `size` and `mime_type` in place of `content`. For anything else you get an error with the size and etag.

### `write_file`

| `status` | Meaning |
|---|---|
| `written` | Done |
| `unchanged` | That exact content was already there |
| `exists` | No `base` given and something's at the path; nothing written |
| `stale` | `base` isn't the current version; nothing written |

Without `base` it only creates. With `base` it's a strict check and never merges. `stale` carries the current etag only where the token may read, so a token can't blindly overwrite a version it can't see. New subfolders are created as needed.

`encoding: base64` writes a binary file, such as an image or a PDF: `content` is its bytes as base64, line breaks allowed, no `data:` prefix. Invalid base64 gives an error, and nothing is written. From claude.ai, Claude types the base64 out itself, token by token, so in practice that means small files.

### `append_file`

For logs, lists and inboxes. It needs no `base` and can't conflict. The text starts on a new line, and a missing file is created.

| `status` | Meaning |
|---|---|
| `appended` | Added to the file |
| `created` | The file was missing, and now exists |
| `unchanged` | The text was empty |

A file that isn't UTF-8 gives an error.

### `delete_file`

| `status` | Meaning |
|---|---|
| `deleted` | Done; empty folders are removed too |
| `gone` | Already gone, which counts as success |
| `stale` | Changed since `base`; nothing deleted. Carries the current etag |

### `download_file`

Saves a file from the web into the vault: the server downloads it, Claude gets only the result. Downloads come only from the hosts on the admin panel's **Download hosts** page (for all tokens): `example.com` for that host, `*.example.com` for its subdomains. Claude isn't told the list in advance: it tries, and a download from a host you haven't approved comes back refused with the URL and the host, which Claude shows you. Add the host, ask it to try again.

- **https only**, port 443. Each redirect must lead to a host on the list too; a refusal names the host, so you can add it.
- **Never a private address:** a host that resolves to a private, loopback, link-local or Tailscale address is refused, whatever the list says, and the server connects to the address it checked. A download can't reach your network, your tailnet or the server itself.
- **Size:** at most `MCP_MAX_WRITE`, stopped as soon as it's over. 60 seconds at most, 2 downloads at a time.
- **Path:** without an extension, it gets the URL's, else one from the file's type. `base` works as for `write_file`: without it the file is only created.
- **History:** the commit is `DOWNLOAD <path>`, with a `Source:` trailer, the URL without its query.

**What the list is for.** Whatever is in a URL reaches its host, so text Claude reads (a web page, a note) could talk it into a URL carrying your notes. Add only hosts you trust with what Claude can read, and not hosting where anyone can get a subdomain and its logs.

## Limits

| Limit | Value |
|---|---|
| `content` / `text` in one call (for base64, the decoded bytes) | `MCP_MAX_WRITE`, 20 MB by default: the plugin's limit on phones, where a bigger file stays on the server |
| Text `read_file` returns | 1 MB: more wouldn't fit in Claude's context anyway |
| An image `read_file` returns | 7.5 MB: the API takes 10 MB per image, base64-encoded. Its cost to Claude's context doesn't grow with the file: a big image is scaled down |
| The request body | Twice `MCP_MAX_WRITE` plus 64 KB (room for JSON's escapes and base64's extra third), at most `MAX_FILE_SIZE`; refused with `413` before it's read |
| Tool calls per token | 60 a minute, counted in memory |
| Downloads | 2 at a time per container, 60 seconds each |

Hitting a limit gives a tool error with a message Claude can act on, such as writing a first part and appending the rest.

## Protocol

`POST /mcp` with `Authorization: Bearer <token>`, JSON-RPC 2.0 over Streamable HTTP, stateless: plain JSON answers, with no sessions or SSE. It handles `initialize`, `notifications/initialized` (`202`), `tools/list`, `tools/call` and `ping`.

| Answer | When |
|---|---|
| `401` + `WWW-Authenticate: Bearer` | No header, or an unknown, revoked or device token |
| `405` + `Allow: POST` | Any method but `POST` |
| `404` | Any path below `/mcp` |
| `413` | Body over twice `MCP_MAX_WRITE` plus 64 KB, or over `MAX_FILE_SIZE` |
| `415` | A form or multipart body (`application/x-www-form-urlencoded`, `multipart/*`): never read |

To try it by hand:

```sh
curl https://notes.example.com/mcp \
  -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_access","arguments":{}}}'
```
