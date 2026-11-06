# Releases

What changes for you when updating. Every release's full list of commits is on its GitHub release page.

## Unreleased

### Breaking: `ENABLED_APPS` decides what a server process serves

The sync API, MCP and the admin panel are now apps a container serves only when listed in `ENABLED_APPS` (comma-separated: `sync`, `mcp`, `admin`; unset: `sync`). So the admin panel can run in a container of its own that nothing public reaches ([Processes](deployment.md#processes)).

- **`MCP_ENABLED` is gone.** A server that still has it set refuses to start, with `MCP_ENABLED is gone: list mcp in ENABLED_APPS instead`. Remove it and add `mcp` to `ENABLED_APPS`, such as `ENABLED_APPS=sync,mcp`.
- **The admin panel no longer turns on with its settings.** Add `admin` to `ENABLED_APPS`. Its settings without `admin` there are ignored, with one log line: `admin env set, admin not enabled`. With `admin` and settings missing, the server refuses to start, as before.
- **Recommended:** move the admin panel into a second container from the same image, on the same `/vaults` and `/db`, reachable only from your private network or the machine itself ([example](deployment.md#processes)), and drop the admin settings from the public one.
- One container with all three (`ENABLED_APPS=sync,mcp,admin`) still works, and is fine while nothing reaches it from outside.
- The admin panel now always shows **Scoped tokens**, since MCP may run in another container.
- `INIT_VAULT_NAME` and `INIT_VAULT_CODE` are acted on only in a container serving `sync`.
- The log's `admin disabled` and `MCP disabled` are replaced by one line per start: `vault-sync: serving <apps>`.

### Paths a vault can't hold get `400`

The server now checks every path against one rule ([Storage](storage.md#paths)) before it reads or writes anything. Paths with a hidden segment (`.gitignore`, `.git/…`, `.obsidian/…`) other than a folder's `.keep`, empty / `.` / `..` segments, control characters, a backslash, a leading `~`, a `git~1` segment, a segment over 255 bytes or a path over 1024 bytes get `400` from the sync API, on `GET` and `DELETE` too, and an error from MCP. Before, some of these were written, some failed with `500`, and some left a vault that took no more writes.

- **The plugin isn't affected:** it never syncs hidden paths. A note whose name the rule refuses for another reason (it starts with `~`, say) stays on its device with a grey dot ("Not synced: the last upload failed") and a sync error. Rename it to sync it.
- **Git no longer looks at the vault's files.** A `.gitignore`, `.gitattributes` or nested `.git` folder inside a vault can't change what's stored or block writes any more, and a failed write leaves the vault as it was.
- **Check the log after updating.** A vault that already holds refused paths is named at startup, with how to clean it up in [Storage](storage.md#cleaning-up-refused-paths). Nothing is deleted on its own.

### Long polls, form bodies, the vault header, logs

- **Long polls are capped:** at most 2 waiting polls per token and 12 per server process. One over gets `429` with `Retry-After: 5` at once; the plugin backs off as after any failed poll. A poll whose token was revoked while it waited gets `401` instead of the manifest ([API](api.md)).
- **Form bodies get `415`:** the sync API and MCP never read `application/x-www-form-urlencoded` or `multipart/*` bodies. Without credentials such a request gets the usual `401`. A script using curl's `-d` / `--data-binary` needs `-H 'Content-Type: application/octet-stream'` (or `text/markdown`).
- **`X-Rock-Sync-Vault` on every route:** `GET /vaults` and `DELETE /token` now refuse the header too when it isn't the token's vault (`401`, as elsewhere). The plugin sends it with `DELETE /token`, so a proxy allowing one vault lets its Remove through.
- **Verbose logs carry less:** with `VERBOSE_HTTP_LOGS` on, credential-like headers (`Proxy-Authorization`, Cloudflare Access headers, anything named like a token, key or secret) and answer bodies (file content, manifests) are left out. It's for debugging, not for production.
- **rack 3.2.8, sqlite3 2.10.2**, for their security advisories.
