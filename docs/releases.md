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
