# Deployment

How it makes sense to run a Rock Sync server. For the image's settings, see [Container](container.md).

## The shape

One small machine you control: a home server or a cheap VPS.

```
 devices ── VPN or private network ──┐
                                     ├── HTTPS proxy ── rock-sync container ── /vaults
 Claude ── internet, /mcp only ──────┘                                     └── /db
```

- **One container.** The server is a single process, with locks and limits in memory, so it doesn't scale out. It doesn't need to: it serves one person.
- **One server, many vaults.** A separate vault for work on the same server gives that laptop's token access to the work vault alone.
- **A token per device and vault.** Lose a phone, revoke its tokens.

It needs little: memory for a Ruby process, and disk for your vault plus its full history. Each running plugin holds one of the server's 16 threads in a long poll almost all the time, so about ten devices at once is the comfortable limit.

## Network

Tokens and notes travel in the clear unless you add encryption, so the server should always sit behind HTTPS or a private network. Decide what needs to be reachable from where:

| Path | Who needs it | Where to put it |
|---|---|---|
| `/files`, `/manifest`, `/vaults`, `/token`, `/move`, `/merge`, `/pair` | Your devices | A VPN such as WireGuard or Tailscale, if you can |
| `/admin` | You | Private only |
| `/mcp` | Anthropic's servers, only with [`MCP_ENABLED`](mcp.md#connecting-claude) | Public HTTPS |
| `/health` | Docker, your monitoring | Private; it reveals nothing, though |

**Recommended: a private network for everything, and `/mcp` alone in public** if you use Claude. Phones and laptops then sync from anywhere without anything else being exposed.

**The sync API can also be public.** Every request needs a token too long to guess, so this is reasonable if a VPN doesn't suit your devices. The exception is `/pair`, which takes a [short one-time code](security.md#connection-codes): its limits leave a few guesses per code, but anyone can keep cancelling your codes. Keep `/admin` private even then, because its [lockout](security.md#admin-panel) can be abused to lock you out.

## Reverse proxy

Any proxy works, provided that:

| It must | Because |
|---|---|
| Terminate HTTPS and send `X-Forwarded-Proto: https` | Without it [the admin login fails](admin.md#turning-it-on) |
| Hold requests for over 60 seconds | Long polls wait up to 60 s (the plugin asks for 25). If they get cut short, the plugin treats it as a failure and backs off |
| Accept bodies up to `MAX_FILE_SIZE` | 100 MB by default; a lower limit makes big files fail with a proxy's error |
| Pass `Authorization`, `ETag`, `If-Match`, `If-None-Match`, `Destination` untouched | The sync protocol depends on them |

[Caddy](https://caddyserver.com) does all of this by default. Everything on a private address, with `/mcp` alone on a public one:

```
notes.internal.example.com {
	reverse_proxy rock-sync:9292
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

Caddy gets the public name's certificate by itself. A name that exists only on your private network can't get one the usual way. Use your VPN's own HTTPS if it has it (Tailscale Serve, for example), a DNS challenge, or `tls internal` with Caddy's root certificate installed on each device. Both sites assume Caddy shares a Docker network with the container.

On nginx, look at `client_max_body_size`, `proxy_read_timeout` and `proxy_set_header X-Forwarded-Proto $scheme`. Set `PUBLIC_URL` to the address your devices use and, if Claude reaches the server elsewhere, `MCP_BASE_URL=https://notes.example.com` so the admin panel shows connectors the public address.

Don't publish the container's port on a public interface: bind it to `127.0.0.1`, or leave it unpublished and put the proxy on the same Docker network.

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
docker compose stop rock-sync
tar czf "rock-sync-$(date +%F).tar.gz" -C /srv/rock-sync vaults db
docker compose start rock-sync
```

A filesystem snapshot of both at one moment works without stopping. Copying a running server's database file alone isn't safe; use `sqlite3 vault-sync.db '.backup <file>'` for that.

**Restoring:** put both directories back and start. If only `/vaults` survived, an empty `/db` works too: create each vault again under the same name ([admin panel](admin.md#vaults) or `INIT_VAULT_NAME`), which adopts its repository with its history, then connect the devices again with new codes. Revoked tokens and MCP grants are lost that way.

Try a restore once, on another machine or port, before you need it.

## Updates

Pin the version in `compose.yml` instead of using `latest`:

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
- [ ] `/admin` isn't public
- [ ] `/vaults` and `/db` are separate mounts on a disk with room to grow
- [ ] A version is pinned in `compose.yml`
- [ ] The admin secrets are in a password manager
- [ ] Backups run, and a restore has been tried
- [ ] The admin login works over the proxy
