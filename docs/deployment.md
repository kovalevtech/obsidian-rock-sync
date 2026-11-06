# Deployment

How it makes sense to run a Rock Sync server. For the image's settings, see [Container](container.md).

## The shape

One small machine you control: a home server or a cheap VPS.

```
 devices ── VPN or private network ──┐                 ┌─ rock-sync (sync, mcp) ──┬── /vaults
                                     ├── HTTPS proxy ──┤                          └── /db
 Claude ── internet, /mcp only ──────┘                 │
 you ───── private network only ── HTTPS proxy ────────┴─ rock-sync-admin (admin) ─ the same /vaults, /db
```

- **Two containers, one image.** One serves the sync API and MCP, the other the admin panel, on the same data. Only the first may ever be reachable from outside: see [Processes](#processes).
- **No replicas.** Some limits live in each process's memory (rate limits, the admin lockout), so running the same app twice doesn't scale out; it doesn't need to: it serves one person.
- **One server, many vaults.** A separate vault for work on the same server gives that laptop's token access to the work vault alone.
- **A token per device and vault.** Lose a phone, revoke its tokens.

It needs little: memory for a Ruby process or two, and disk for your vault plus its full history. Each running plugin holds one of the server's 16 threads in a long poll almost all the time, so about ten devices at once is the comfortable limit.

## Processes

`ENABLED_APPS` decides what a container serves, comma-separated:

| App | Paths | Needs |
|---|---|---|
| `sync` | The sync API: `/files`, `/manifest`, `/move`, `/merge`, `/vaults`, `/token`, `/pair` | Nothing more |
| `mcp` | `/mcp`, for [Claude](mcp.md) | Nothing more |
| `admin` | `/admin`, the [admin panel](admin.md) | `PUBLIC_URL`, `ADMIN_USER`, `ADMIN_PASSWORD`, `SESSION_SECRET` |

Unset, it's `sync`: MCP and the admin panel are there only when listed. Every container answers `/health`. A path of an app the container doesn't serve is like any unknown path: nothing tells it apart from one that doesn't exist anywhere.

**Recommended: the admin panel in a container of its own that no proxy, tunnel or public port reaches**, only a private network or the machine itself. A proxy rule meant for other paths then can't lead to `/admin`, whatever the path looks like: that container isn't behind it. Both containers mount the same `/vaults` and `/db`, from the same image version:

```yaml
x-rock-sync: &rock-sync
  image: ghcr.io/kovalevtech/obsidian-rock-sync:1.2.3
  user: "1000:1000"
  volumes:
    - /srv/rock-sync/vaults:/vaults
    - /srv/rock-sync/db:/db
  restart: unless-stopped

services:
  rock-sync:            # behind the proxy: devices, and /mcp in public
    <<: *rock-sync
    environment:
      ENABLED_APPS: sync,mcp
  rock-sync-admin:      # the private proxy only
    <<: *rock-sync
    environment:
      ENABLED_APPS: admin
      PUBLIC_URL: https://notes.internal.example.com
      MCP_BASE_URL: https://notes.example.com
      ADMIN_USER: ${ADMIN_USER}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      ADMIN_TOTP_SECRET: ${ADMIN_TOTP_SECRET}
      SESSION_SECRET: ${SESSION_SECRET}
```

The containers coordinate through lock files on the shared mounts: writes to a vault wait for each other, the database is migrated once when they start together, and a vault created in the panel is usable right away. A long poll hears about a commit made in the other container (MCP's, say) within 2 seconds. `sync` and `mcp` can also run apart, one container each. `INIT_VAULT_NAME` and `INIT_VAULT_CODE` only act where `sync` runs, since the code is used there.

The admin panel still needs HTTPS for its login ([why](admin.md#turning-it-on)), so put it behind a proxy on your private network, as in the [example below](#reverse-proxy), or your VPN's own HTTPS.

**One container with everything** (`ENABLED_APPS=sync,mcp,admin`) is fine while nothing reaches it from outside: on this machine, or a private network only. The moment any part of it is exposed, through a proxy, a tunnel, a public port or your VPN's public sharing, even `/mcp` alone, the admin panel is one crafted path away from whoever can send a request there. Move it to its own container first.

## Network

Tokens and notes travel in the clear unless you add encryption, so the server should always sit behind HTTPS or a private network. Decide what needs to be reachable from where:

| Path | Who needs it | Where to put it |
|---|---|---|
| `/files`, `/manifest`, `/vaults`, `/token`, `/move`, `/merge`, `/pair` | Your devices | A VPN such as WireGuard or Tailscale, if you can |
| `/admin` | You | Private only, in [a container of its own](#processes) |
| `/mcp` | Anthropic's servers, only with `mcp` in [`ENABLED_APPS`](#processes) | Public HTTPS |
| `/health` | Docker, your monitoring | Private; it reveals nothing, though |

**Recommended: a private network for everything, and `/mcp` alone in public** if you use Claude. Phones and laptops then sync from anywhere without anything else being exposed.

**The sync API can also be public.** Every request needs a token too long to guess, so this is reasonable if a VPN doesn't suit your devices. The exception is `/pair`, which takes a [short one-time code](security.md#connection-codes): its limits leave a few guesses per code, but anyone can keep cancelling your codes. Keep the admin container private even then: besides the panel itself, its [lockout](security.md#admin-panel) can be abused to lock you out.

## Reverse proxy

Any proxy works, provided that:

| It must | Because |
|---|---|
| Terminate HTTPS and send `X-Forwarded-Proto: https` | Without it [the admin login fails](admin.md#turning-it-on) |
| Hold requests for over 60 seconds | Long polls wait up to 60 s (the plugin asks for 25). If they get cut short, the plugin treats it as a failure and backs off |
| Accept bodies up to `MAX_FILE_SIZE` | 100 MB by default; a lower limit makes big files fail with a proxy's error |
| Pass `Authorization`, `ETag`, `If-Match`, `If-None-Match`, `Destination` untouched | The sync protocol depends on them |

[Caddy](https://caddyserver.com) does all of this by default. Everything on a private address, with `/mcp` alone on a public one, and the admin panel only on the private one, from its own container:

```
notes.internal.example.com {
	handle /admin* {
		reverse_proxy rock-sync-admin:9292
	}
	handle {
		reverse_proxy rock-sync:9292
	}
}

notes.example.com {
	handle /mcp {
		reverse_proxy rock-sync:9292
	}
	handle {
		respond 404
	}
}
```

Caddy gets the public name's certificate by itself. A name that exists only on your private network can't get one the usual way. Use your VPN's own HTTPS if it has it (Tailscale Serve, for example), a DNS challenge, or `tls internal` with Caddy's root certificate installed on each device. Both sites assume Caddy shares a Docker network with the containers.

On nginx, look at `client_max_body_size`, `proxy_read_timeout` and `proxy_set_header X-Forwarded-Proto $scheme`. Set `PUBLIC_URL` to the address your devices use and, if Claude reaches the server elsewhere, `MCP_BASE_URL=https://notes.example.com` so the admin panel shows connectors the public address.

Don't publish the containers' ports on a public interface: bind them to `127.0.0.1`, or leave them unpublished and put the proxy on the same Docker network.

## Storage

Keep `/vaults` and `/db` as two separate mounts. Bind mounts to directories you back up are easier to reason about than named volumes; run the container [as their owner](container.md#which-user).

- **Disk:** plan for the vault's size times a few, since every version of every file stays forever. [Compact](storage.md#compacting) now and then; it mostly helps with text. Large binaries that change often are what make a repository balloon.
- **Encryption at rest:** the server stores plain files ([Security](security.md#notes-at-rest)). If that matters, encrypt the disk under the mounts.
- **Mounts that may be absent:** the server refuses to start when a mount is missing, as long as the database remembers its vaults. If `/db` and `/vaults` both come up empty, it can't tell that from a fresh install, and `INIT_VAULT_NAME` will create a new vault there, with `INIT_VAULT_CODE` open again. On such a server, remove `INIT_*` after the first start.

## Secrets

Keep them in a `.env` file next to `compose.yml`, readable only by you (`chmod 600`), and copies in a password manager. They are `ADMIN_PASSWORD`, `ADMIN_TOTP_SECRET` if you use it, `SESSION_SECRET` and, until its device has connected, `INIT_VAULT_CODE`. Changing `SESSION_SECRET` only logs you out of the panel. Scoped tokens are shown once, so put them into the connector right away.

## Backups

Your devices hold the current files, but not the history and not each other's unsynced work, and a device deleting everything would sync that. Back up the server.

**What:** `/vaults` and `/db`, taken together, so that they agree.

**How:** the simplest consistent way is to stop the container, copy both directories and start it again:

```sh
docker compose stop rock-sync rock-sync-admin
tar czf "rock-sync-$(date +%F).tar.gz" -C /srv/rock-sync vaults db
docker compose start rock-sync rock-sync-admin
```

A filesystem snapshot of both at one moment works without stopping. Copying a running server's database file alone isn't safe; use `sqlite3 vault-sync.db '.backup <file>'` for that.

**Restoring:** put both directories back and start. If only `/vaults` survived, an empty `/db` works too: create each vault again under the same name ([admin panel](admin.md#vaults) or `INIT_VAULT_NAME`), which adopts its repository with its history, then connect the devices again with new codes. Revoked tokens and MCP grants are lost that way.

Try a restore once, on another machine or port, before you need it.

## Updates

Pin the version in `compose.yml` instead of using `latest`, the same for every container (the example above keeps it in one place):

```sh
# back up first: database migrations run at startup and don't run backwards
sed -i 's/obsidian-rock-sync:1.2.3/obsidian-rock-sync:1.2.4/' compose.yml
docker compose up -d
```

The plugin and the image share version numbers, since each release publishes both. Update both around the same time.

## Monitoring

- `GET /health` answers `ok` with no credentials. Docker tracks it through the image's `HEALTHCHECK`.
- A container that keeps exiting will have [one line in its log](container.md#why-it-wont-start) saying why.
- Watch the disk, the only resource likely to run out.
- The admin panel shows when each token was last seen, which also helps you spot a device that stopped syncing.

## Checklist

- [ ] The server is reachable only through HTTPS or a private network
- [ ] No container with `admin` in `ENABLED_APPS` is reachable through a proxy, tunnel or public port
- [ ] `/vaults` and `/db` are separate mounts on a disk with room to grow
- [ ] A version is pinned in `compose.yml`
- [ ] The admin secrets are in a password manager
- [ ] Backups run, and a restore has been tried
- [ ] The admin login works over the proxy
