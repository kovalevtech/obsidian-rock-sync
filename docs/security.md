# Security

Rock Sync is built for one person running their own server. This page says what protects your notes, and what doesn't.

## Tokens

There are two kinds, and neither works where the other does.

| | Device token | Scoped token |
|---|---|---|
| For | The plugin on one device | One MCP connector |
| Reaches | The [sync API](api.md) | [`POST /mcp`](mcp.md) only |
| Sent as | `Authorization: Basic base64("<vault>:<token>")` | `Authorization: Bearer <token>` |
| Limits | One vault, the code's; everything inside it | The folders and modes in its [grants](mcp.md#grants) |
| Created by | A [connection code](#connection-codes) | Admin panel |

A device token is per device and vault, a scoped token per connector. A token's name is the author of its commits, and revoking one doesn't touch the others.

**Generation.** The server makes 32 random bytes in base64url. A device token goes straight to the plugin, which keeps it and never shows it; a scoped token is shown once, on the page right after creation: put it into the connector, and into a password manager if you like.

### Connection codes

The [admin panel](admin.md#device-tokens) issues a one-time, 6-digit code for a vault (or, **Reconnect**, for an existing token), and [`POST /pair`](api.md#post-pair) trades it for a device token without credentials. So a code is as good as a token for its vault until it's used or its 10 minutes are up: treat it like one. It's in the database in the clear while it's active, because a hash of six digits would hide nothing, and the row goes when the code is used, expired or cancelled. Six digits can be guessed, so 5 wrong codes in a row cancel all active ones and there are at most 10 attempts a minute: that's 5 guesses in a million for each code you issue. The cost is that anyone who can reach the server can keep cancelling codes, so you'd have to issue another; existing tokens aren't affected.

`INIT_VAULT_CODE` (the [first run](container.md#first-run)) is a code without an expiry, until the vault's first device uses it. 5 wrong codes cancel it until the next start, so an attacker gets 5 guesses in a million per restart of your server. Once a device of the vault has a token it never works again, so leaving it in the environment afterwards is harmless.

**Storage on the server.** Only the SHA-256 of a token is stored. A random 32-byte token can't be brute-forced, so a slow salted hash would only add cost to every request.

**Storage on a device.** The plugin keeps its token in Obsidian's per-vault localStorage: never in the vault's files or in `data.json`, so it doesn't sync and doesn't leave with a copied `.obsidian` folder. It isn't encrypted, and **any other plugin in that Obsidian vault can read it**. A plugin runs with full access in any case, so install only ones you trust.

**Paths from the server.** The plugin writes only vault paths it got from the server's manifest, and it checks them against the server's own rule first: a path with `..`, `.` or empty segments, a `\`, control characters, or a leading `/` or `~` is dropped with a warning in the developer console, never written. Obsidian's file API would otherwise resolve `..` and write outside the vault, so a malicious server, or anyone between it and an `http://` connection, can't plant files elsewhere on the device.

**Revoking.** [Revoke](admin.md#device-tokens) a lost device's token in the admin panel: it stops working at once and stays revoked. The plugin's **Remove**, and connecting a vault elsewhere, revoke the token it had (`DELETE /token`).

**Failures reveal nothing.** Every refused request gets the same `401`, whether the token is unknown or revoked, the vault doesn't exist, or the token may not use it. With [`VERBOSE_HTTP_LOGS`](container.md) on, the reason goes to the server log for the sync API; for MCP the log says only "mcp auth failed". With it off, the reason isn't recorded.

## Logs

Logs never contain the `Authorization` header, cookies, request bodies, MCP answers or `POST /pair` answers, and neither tokens nor connection codes are logged at any point. They do contain paths, device and token names, and the vault's name, so treat file names in your logs as private.

With `VERBOSE_HTTP_LOGS` on there's a line for each request and answer, with the request's headers but none that carries credentials (`Authorization`, `Proxy-Authorization`, cookies, Cloudflare Access' `Cf-Access-Client-Id`, `Cf-Access-Client-Secret` and `Cf-Access-Jwt-Assertion`, and any named like a token, key or secret). Answers are logged only where they hold neither file content nor a secret (`GET /vaults`); for everything else only the status. It's meant for debugging, not for production.

## Transport

The server speaks plain HTTP and expects a proxy or a private network in front of it. Tokens and notes travel in the clear otherwise. See [Deployment](deployment.md#network). The plugin's settings warn about an `http://` server URL, except to the device itself or a Tailscale address (`100.64.0.0/10`, `*.ts.net`), which WireGuard encrypts.

## Exposing the server

Whatever is reachable from the internet should pass a proxy that allows the sync API's and MCP's requests by method and exact path, and nothing else: [Exposing the server](exposing.md) has the rules, a Cloudflare example and checks to run from outside. Behind any proxy, the server refuses a request path that isn't canonical (`//`, `.` or `..` segments, an encoded `/`, `\` or `.`, control characters) with `400` before routing it, so a proxy that reads a path differently can't steer a request past its rules to another part of the server. That is a second line, not a replacement for the allowlist.

## Notes at rest

**There's no end-to-end encryption.** The server stores your notes as plain files, and whoever controls the server can read them. If the disk should be protected, encrypt it at the storage layer; the server doesn't need to know.

## Admin panel

- Off unless `admin` is in `ENABLED_APPS`, which then needs `ADMIN_USER`, `ADMIN_PASSWORD` and `SESSION_SECRET`. Run it in a container of its own that nothing public reaches ([Processes](deployment.md#processes)).
- Login takes a password and, if `ADMIN_TOTP_SECRET` is set, a TOTP code, in one form with one generic error. A code works once. Without TOTP the password alone protects the panel, which is one more reason to keep it private.
- After 5 failed logins, every login is refused for 60 seconds, doubling with each further failure, up to an hour. This is global and in memory: someone who can reach the page can keep you locked out, which is one more reason to keep it [off the internet](deployment.md#network). Restarting the server clears it.
- The session is an encrypted cookie: `HttpOnly`, `SameSite=Strict`, `Secure`, 12 hours. All forms are protected against CSRF.
- A `Content-Security-Policy` allows scripts and styles from the panel's own files only, forms that post to the panel only, and no framing. The pages have no inline scripts, handlers or styles.

## MCP

Off unless `mcp` is in `ENABLED_APPS`: without it the endpoint doesn't exist. Whatever a token may not do with a path reads exactly like a path that isn't there, so it can't probe for files outside its grants. Hidden paths (any segment starting with a dot) can never be granted, listed, read or written. Tool calls are limited to 60 a minute per token, and a request body to twice `MCP_MAX_WRITE` plus 64 KB, refused before it's read. A write can't overwrite a version the token hasn't seen, and results never echo file content.

`download_file` makes the server fetch a URL, so it fetches only from the hosts the admin panel lists, over https only, and nothing while the list is empty. A host resolving to a private, loopback, link-local or Tailscale address is refused, the connection goes to the address that was checked, and every redirect is checked again, so a download can't reach your network or the server itself. What it can't prevent: whatever is in a URL reaches that host. List only hosts you trust with what Claude reads ([MCP](mcp.md#download_file)).

Whatever you grant ends up in a third party's hands: what Claude reads goes to Anthropic under your account's terms.

## What isn't protected

- **Brute force on the sync API** isn't rate limited; the tokens are too long for it to matter.
- **A compromised device** has its token's full access: every file in its vaults, including history. Revoke it. What it already downloaded stays with it.
- **A deletion or overwrite by a valid token** isn't blocked, but it's a commit, so earlier versions stay in git.
- **Availability:** one process on one machine. See [Deployment](deployment.md#backups) for backups.
