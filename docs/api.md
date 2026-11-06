# Sync API

The HTTP API the plugin uses. You need this page only to write another client or to debug with `curl`. [MCP](mcp.md) is a separate surface.

## Authentication

Every request except `GET /health` and `POST /pair` carries the vault and a device token as HTTP Basic:

```
Authorization: Basic base64("<vault>:<token>")
```

```sh
curl -u 'notes:<token>' https://notes.example.com/manifest?v=1
```

Any failure gets the same answer: a malformed header, an unknown or revoked token, a scoped token, an unknown vault, or a vault this token may not use.

```
401 {"error":"unauthorized"}
```

There is no `WWW-Authenticate` header, because a browser would pop up a login dialog. The reason goes only to the server log. Unknown routes need credentials too: 401 without them, 404 with them.

An optional `X-Rock-Sync-Client: plugin=1.0.0; obsidian=1.8.7; platform=macos` header ends up in the commit's `Client:` trailer (printable ASCII, at most 200 characters).

The plugin also sends `X-Rock-Sync-Vault: <vault>`, the vault in the clear, whenever it has one. A proxy in front can't read Basic, but it can let through only some vaults' requests by this header. The header is optional. When it is there, it must equal Basic's vault exactly, else the request gets the same 401. `/vaults` and `/token` ignore it, as they ignore Basic's vault part. On its own it protects nothing, since the client sets it. Combined with a proxy rule, another device's leaked token can't reach any vault from outside except the ones the rule allows.

## Versions

A file's version is its git blob hash, `sha1("blob <size>\0" + content)`, computed over the raw bytes:

```sh
git hash-object note.md
```

File versions travel in an unquoted `ETag`. `Last-Modified` is the time of the last commit touching the file. Paths are relative to the vault and URL-encoded.

Every answer has `Cache-Control: no-store`. If your HTTP client keeps its own cache, turn it off or send `Cache-Control: no-cache`: a cached answer looks like an up-to-date file.

## Endpoints

| Request | Purpose |
|---|---|
| `GET /health` | Liveness, no credentials |
| `POST /pair` | A one-time code and a device name for a device token, no credentials |
| `GET /vaults` | The vaults this token may use |
| `DELETE /token` | The token revokes itself |
| `GET /manifest?v=1` | Every file with its hash and size; long polling |
| `GET /files/<path>` | Read a file |
| `PUT /files/<path>` | Create or update a file, merging if stale |
| `DELETE /files/<path>` | Delete a file |
| `POST /move/<from>` | Rename a file |
| `POST /merge/<path>` | Dry run of `PUT`'s merge |

Encode each segment of `<path>` with `encodeURIComponent` or its equivalent. Before anything else, the server answers `400` with an empty body to a request path that isn't canonical: one with `//`, a `.` or `..` segment, `\`, an encoded `/`, `\` or `.` (`%2F`, `%5C`, `%2E`), a control character raw or encoded, or malformed percent-encoding ([why](security.md#exposing-the-server)).

### `GET /health`

`200 ok` as plain text. Says nothing about vaults or tokens, and isn't logged.

### `POST /pair`

Trades a code from the [admin panel](admin.md#device-tokens) (or `INIT_VAULT_CODE`) and a device name (`[a-z0-9-]`, at most 64 characters) for a device token, allowed into the vault the code was issued for. Other tokens may have the same name (it's only the commit author); a **Reconnect** code keeps its token's name and gives it a new secret instead. The token is shown only in this answer.

```sh
curl -X POST -H 'Content-Type: application/json' -d '{"code":"482913","name":"pixel"}' https://notes.example.com/pair
```

```json
{"token": "<token>", "vault": "notes", "name": "pixel"}
```

| Status | Meaning |
|---|---|
| 200 | The token, its vault and its name; the code is used up |
| 400 | The body isn't a JSON object of at most 1 KB |
| 401 | The code is wrong, used or expired: the same `{"error":"unauthorized"}` for all three |
| 422 | The code is good, the name isn't: `{"error":"<why>"}`. The code keeps working |
| 429 | Over 10 attempts a minute, counted for everyone together |

Spaces in the code don't matter. 5 wrong codes in a row cancel all active ones.

### `GET /vaults`

```json
{"vaults": ["notes"]}
```

The token's vault (one; a list for plugins from before connection codes). Only the token matters here: the vault part of Basic is ignored and may be empty (`-u ':<token>'`).

### `DELETE /token`

Revokes the token it's sent with: the plugin's **Remove**, or a vault connected elsewhere. `204`; the vault part of Basic is ignored.

### `GET /manifest?v=1`

```json
{
  "version": "70c1391bb8cb5fbbe79315e9f92a1468145b541c",
  "files": { "a.md": ["b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", 5] }
}
```

`version` is the vault's HEAD commit, `null` until the first commit. Each file is `[hash, size in bytes]`. Without `v=1` each file is just its hash, for old clients. The response has a quoted `ETag`, an empty vault's too, and answers `304` to a matching `If-None-Match`; send the header back exactly as you received it.

**Long polling:** `GET /manifest?v=1&wait=25` with `If-None-Match: <etag>` holds the request until the vault changes (`200` + manifest) or the time is up (`304`). `wait` is capped at 60 seconds. Without `If-None-Match` it answers right away. Each waiting client holds one server thread.

### `GET /files/<path>`

`200` with the raw bytes, `ETag` and `Last-Modified`. `304` if `If-None-Match` equals the current hash. `404` if there's no such file.

### `PUT /files/<path>`

The body is the file's raw bytes. Identical content always succeeds, whatever the headers.

| Header | Meaning |
|---|---|
| `If-Match: <hash>` | The version your edit is based on |
| `If-None-Match: *` | Create only |
| neither | Overwrite unconditionally |
| `Content-Type` | `text/*` allows a merge; anything else never merges |

| Answer | When | Body |
|---|---|---|
| `204` + `ETag` | Written, or the content was identical | none |
| `200` + `ETag` | `If-Match` was stale, merged cleanly, committed | The merged text: replace your copy with it |
| `409` | `If-Match` was stale and the merge has conflicts; nothing written | Merged text with conflict markers |
| `412` | Nothing to merge: not `text/*`, base unknown, binary, or `If-None-Match: *` on an existing file | The current version; empty if the file is gone |
| `400` | Bad path | |
| `413` | Over `MAX_FILE_SIZE`, judged by `Content-Length` before the body is read | |

`409` and `412` carry the `ETag` and `Last-Modified` of the current server version. To resolve a conflict, push the result with `If-Match` set to that `ETag`.

Conflict markers are nine characters long, so a line of seven `=` in a note isn't mistaken for one. The labels are `server <UTC time>` and `mine`:

```
<<<<<<<<< server YYYY-MM-DDTHH:MMZ
their line
=========
my line
>>>>>>>>> mine
```

### `DELETE /files/<path>`

`If-Match` is required: the version you meant to delete.

| Answer | When |
|---|---|
| `204` | Deleted, or already gone |
| `412` + current version, `ETag`, `Last-Modified` | Edited since, or no `If-Match`; nothing deleted |

### `POST /move/<from>`

`Destination: <to>` names the new path, URL-encoded like the request path. There's no `If-Match`: whatever version is at `from` moves, so `git log --follow` keeps the history.

| Answer | When |
|---|---|
| `204` + `ETag` at the new path | Moved |
| `400` | No `Destination` header, or a bad path |
| `404` | `from` is missing |
| `409` | `to` is taken |

### `POST /merge/<path>`

The same merge as `PUT`, but nothing is ever written. `If-Match` is the base, the body is your version.

| Answer | Body |
|---|---|
| `200` | The clean merge |
| `409` | Text with conflict markers |
| `412` / `413` | As for `PUT` |

`ETag` and `Last-Modified` describe the current server version.

## What the client has to do

The server only stores and merges. Deciding what to sync is the client's job:

- Remember the hash each file had at the last sync (the base). Comparing base, local and remote tells you what changed where.
- Folders are empty `<folder>/.keep` files on the server.
- Send `text/*` only for files that may be merged. A merge with markers breaks formats that merely look like text, such as SVG or Canvas. The plugin sends `text/markdown` for `.md` except `.excalidraw.md`, and `application/octet-stream` for everything else.
