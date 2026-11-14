# Admin panel

The panel at `/admin` manages vaults and tokens. It's optional: without it the server still runs, and [`INIT_VAULT_NAME` and `INIT_VAULT_CODE`](container.md#first-run) can set up one vault and connect its first device. Every other device needs a code from here.

## Turning it on

Add `admin` to [`ENABLED_APPS`](deployment.md#processes), and set the user, the password, the session secret and the public URL. Without `admin` there the panel doesn't exist, whatever else is set. With it, and any of these missing, the server refuses to start.

Run it in a container of its own, on the same mounts as the one serving sync, that no proxy, tunnel or public port reaches: only your private network or the machine itself ([Processes](deployment.md#processes)).

| Setting | Value |
|---|---|
| `PUBLIC_URL` | The address your devices reach the server at, such as `https://notes.example.com`. The panel gives it out with a [connection code](#device-tokens) |
| `ADMIN_USER` | Your user name |
| `ADMIN_PASSWORD` | A long password |
| `SESSION_SECRET` | At least 64 bytes |
| `ADMIN_TOTP_SECRET` | Optional. Base32, at least 128 bits. Add the same string to your authenticator app |

```sh
# ADMIN_TOTP_SECRET
docker run --rm --entrypoint bundle ghcr.io/kovalevtech/obsidian-rock-sync:latest \
  exec ruby -rrotp -e 'puts ROTP::Base32.random'

# SESSION_SECRET
openssl rand -hex 64
```

**It needs HTTPS.** In production the session cookie is `Secure`, and the server only sets it on a request it knows is HTTPS. Over plain HTTP the login page opens but logging in answers `403`. Your proxy must send `X-Forwarded-Proto: https` ([Deployment](deployment.md#reverse-proxy)).

**TOTP is optional, and worth having.** Without `ADMIN_TOTP_SECRET` the login form has no code field and the password alone protects the panel, so make it long; the log says so at every start.

Keep it off the public internet ([why](security.md#admin-panel)).

## Logging in

User name, password and, with TOTP, the current code, in one form. A code works only once, so a second login within the same 30 seconds has to wait for the next code. After 5 failures, all logins are refused for 60 seconds, doubling with each further failure up to an hour; restarting the container that serves the panel clears that. The session lasts 12 hours.

## Vaults

Lists each vault's sizes, its device tokens and its object counts. **Connect device** under a vault's tokens issues a code for it, see below.

| Column | Meaning |
|---|---|
| Files | The current files |
| History | The git repository on disk. Compressed, so it can be smaller than Files |
| Total | The vault on disk |

- **New vault:** `[a-z0-9-]`, at most 64 characters. If a repository with that name is already in `VAULTS_DIR`, it's adopted with its history.
- **Compact:** runs `git gc` in the background. See [Storage](storage.md#compacting).
- **History:** what happened to the vault's files, see below.

Vaults can't be deleted or renamed here.

## History

A vault's **History** answers "what happened to my files, who did it, when", without scrolling through every autosave. It only shows; nothing can be restored from it yet.

Three tabs:

- **All:** every entry, newest first.
- **Deleted:** files and folders that are deleted now. A file created again at the same path leaves the list.
- **Moves:** renames and moves.

Entries group the commits:

| Entry | What it is |
|---|---|
| Edited | One file, one author, each commit less than 15 minutes after the previous one. The window slides: three hours of autosaves every few seconds are one entry. Edits to other files in between don't split it; an edit by another author does. Server merges and MCP appends count as edits |
| Created | The same, starting with the file's creation |
| Deleted, Moved | Always an entry of their own; they end the file's run |
| Folder deleted, Folder moved | A folder deleted or renamed in Obsidian reaches the server as one commit per file plus one for the folder. Those commits become one entry, with its files one click away: the deletions (renames) of one author, each less than a minute after that author's previous one, under a folder whose own deletion (rename) is among them. A subfolder goes into the outermost folder |

Each entry shows the file, the author (name and kind: `device`, `token` for MCP, `unknown` for the server's own commits and adopted history), the time span and the number of versions. Open one to see:

- **Edits:** a diff from the version before the run to its last version, then each version's own diff.
- **A created or deleted file:** its content (for a deleted one, the last version).
- **Images:** shown. **PDFs and other binary files:** size and a download.
- **Too large:** text over 1 MB or a diff over 5000 lines. Download only.

**Filters** apply to every tab and stay in the URL: author (any part of the name, any case; the field suggests the names in the history), file (any part of the path, so a folder's path finds what's in it), dates and presets (the last 24 hours, 7 days, 30 days, year). Dates and times are UTC, as everywhere in the panel.

Not shown: hidden paths (`.plugins/…`, anything with a segment starting with a dot) and folders' `.keep` files. Renames aren't followed: a file's history before it got its name is under its old name.

Downloads are served as attachments, under a policy that runs nothing, so a file from a device can't do anything in the panel. That includes SVG images, which are shown only as images.

The history is indexed in the database when the page opens: the first time the whole history (a 50,000-commit vault took about a second; past 100,000 new commits it runs in the background and the page shows "Indexing…"), later only the new commits. The index is a cache: it can be deleted at any time, and is rebuilt when the history was rewritten.

## Device tokens

One per device and vault: a phone syncing two vaults has two. The name becomes the author of its commits. Tokens come only from connection codes, typed into the [plugin's settings](plugin.md#connecting); the plugin never shows a token.

- **Connect device** (here or on the Vaults page): pick a vault and get a 6-digit code with the server URL, and both as one connection link (`<PUBLIC_URL>?code=…`) to paste into the plugin. The device names itself and gets its token; several tokens may share a name. A code works once, for 10 minutes; 5 wrong codes in a row cancel all active ones.
- **Reconnect:** a code for this token: the device that uses it gets a new token under the same name, for the same vault, and the old token stops working. For a reinstalled device, or one whose token was refused.
- **Revoke:** it stops working at once. The plugin's **Remove** revokes its token too.
- The list shows active tokens; **Show revoked** includes revoked ones.

## Scoped tokens

One per [MCP connector](mcp.md). The page is always there; the tokens work where `mcp` is in [`ENABLED_APPS`](mcp.md#connecting-claude), in this container or another. The list shows each token's grants, when it was created and last used, and its status. **Show revoked** includes revoked ones.

- **New token:** a name and at least one [grant](mcp.md#grants). The next page shows the token once, with the URL and header for the connector.
- **Edit:** the name and all grants are saved together, or not at all, with errors shown on their rows. Renaming changes the author of later commits only.
- **Folder field:** suggests the vault's folders and says "folder missing" for one that isn't there.
- **Purpose:** folded under the grant; open it to write your instructions.
- **Revoke:** the connector stops working at once, and the page turns read-only.

"**check grants**" on a token means its grants wouldn't pass a save any more, for example after a folder rename landed one under another. They keep working; the token's page shows what to fix.

## Download hosts

Where Claude's [`download_file`](mcp.md#download_file) may save files from, for all scoped tokens: a host (`example.com`) or its subdomains (`*.example.com`). A pasted URL stands for its host. A download from any other host is refused, and Claude shows you its URL and host to add here; then ask it to try again.

Many sites serve files from a CDN on another domain: the refusal names the host the download was redirected to, so you can add that one too.

## What's stored

The panel writes only to the database and to `VAULTS_DIR`. See [Storage](storage.md#database).
