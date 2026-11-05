# Container

The server ships as a Docker image for `linux/amd64`: `ghcr.io/kovalevtech/obsidian-rock-sync`, tagged `<version>` and `latest`. For a minimal `compose.yml`, see the [quick start](../README.md#quick-start); for what to put around it, [Deployment](deployment.md).

## First run

These make it possible to start syncing with nothing else set up. Each start creates only what's missing.

| Setting | Meaning |
|---|---|
| `INIT_VAULT_NAME` | A vault to create, `[a-z0-9-]`. Can be set alone |
| `INIT_VAULT_CODE` | A [connection code](plugin.md#connecting) for its first device: 6 digits you pick. Needs `INIT_VAULT_NAME` |

Unlike the admin panel's codes, this one has no expiry, but it connects one device only: once the vault has a device token (even a revoked one), it's gone for good, and restarts don't bring it back. 5 wrong codes in a row cancel it until the next start. It's a secret until used: keep it out of logs and shared files.

| When you restart with… | What happens |
|---|---|
| The same values, code not used | Nothing changes; the code still works |
| The same values, code used | Nothing changes; a line in the log says the code is ignored |
| Another `INIT_VAULT_CODE`, not used | The new code replaces the old one |
| No `INIT_VAULT_CODE` | No code; the vault stays |
| A new `INIT_VAULT_NAME` | That vault is created too |

For more devices and vaults, use the [admin panel](admin.md). There are no commands for this in the image.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `VAULTS_DIR` | `/vaults` | Where the vaults live |
| `DB_DIR` | `/db` | The database's directory |
| `PORT` | `9292` | The port inside the container |
| `MAX_FILE_SIZE` | `104857600` | Largest request body in bytes (100 MB) |
| `MCP_ENABLED` | off | `true` or `1`: the [MCP](mcp.md) endpoint and the admin panel's scoped tokens |
| `MCP_MAX_WRITE` | `1048576` | The most one MCP call may write or read, in bytes (1 MB) |
| `MCP_BASE_URL` | | The origin Claude reaches the server at, for a new token's MCP URL in the admin panel. Empty: `PUBLIC_URL` |
| `VERBOSE_HTTP_LOGS` | off | `true` or `1`: a log line for every request and answer, including why a request was refused |
| `INIT_VAULT_NAME`, `INIT_VAULT_CODE` | | [First run](#first-run) |
| `PUBLIC_URL`, `ADMIN_USER`, `ADMIN_PASSWORD`, `SESSION_SECRET`, optionally `ADMIN_TOTP_SECRET` | | [Admin panel](admin.md#turning-it-on) |

The server doesn't read `.env` files in the image: everything comes from the container's environment. [`backend/.env`](../backend/.env) lists the same settings for running without Docker.

## Volumes

Both directories must exist and be writable. The server creates neither.

| Path | Holds |
|---|---|
| `/vaults` | The vaults, your data |
| `/db` | The database. A directory, not a file: SQLite puts `-wal` and `-shm` next to it |

## Which user

The image starts as root, which is fine with named volumes. For bind mounts, run it as the owner of the files:

```yaml
    user: "1000:1000"
    volumes:
      - /srv/rock-sync/vaults:/vaults
      - /srv/rock-sync/db:/db
```

Any uid works, with or without a passwd entry. It must match the owner of the files, or git will refuse the repositories as "dubious ownership". The server writes only under the two volumes, so `--read-only` works too.

## Why it won't start

A failed start is one line in the log and exit code 1. Secrets are named, never shown.

| Log line, after `vault-sync: not starting:` | Fix |
|---|---|
| `database directory missing: /db (not mounted?)` | Mount `/db` |
| `vaults directory missing: /vaults (not mounted?)` | Mount `/vaults` |
| `vault <name> missing: no /vaults/<name>/repo.git` | The database knows a vault that isn't there: the wrong or an empty volume is mounted at `/vaults` |
| ``Environment variable `<names>` must be defined.`` | Set the rest of the admin settings, or `INIT_VAULT_NAME` for a code |
| `ADMIN_TOTP_SECRET must be base32, at least 128 bits` | [Generate one](admin.md#turning-it-on) |
| `SESSION_SECRET must be at least 64 bytes` | [Generate one](admin.md#turning-it-on) |
| `PUBLIC_URL must be the http(s) address devices reach this server at` | [Set it](admin.md#turning-it-on) to `https://…` or `http://…`, with no query |
| `INIT_VAULT_CODE must be 6 digits` | Six digits, nothing else |

These are refusals by design. A server that started on unmounted storage would look like an empty vault, and that must never reach your devices.

## Running

- **Health:** the image has a `HEALTHCHECK` on `GET /health`.
- **Logs:** on stdout, with no secrets or note contents ([Security](security.md#logs)). Log lines of the server's own start with `vault-sync:`.
- **Stopping:** `docker stop` is a clean stop, waiting long polls are woken first, and it exits with 0.
- **One container per data directory:** locks and limits live in memory, so don't run replicas.

## Building it yourself

```sh
cd backend
make image   # for this machine: obsidian-rock-sync:<version> and :latest
```
