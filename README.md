# Rock Sync

Self-hosted, single-user sync for Obsidian: a plugin on every device and one server that keeps your vaults in git.

- **Every file type, every version.** Each change is a commit, so nothing you synced is lost.
- **Real merges.** The server merges edits to the same note, and you only resolve what truly conflicts, in a view of its own.
- **Nothing is deleted behind your back.** A deletion from another device waits for your confirmation.
- **Several vaults, a token per device and vault,** connected with a one-time code, revocable at any time.
- **Claude can read and write** the folders you choose, through MCP, if you turn it on.

```
 Obsidian + plugin ──┐
 Obsidian + plugin ──┼── sync API ──┐
 Obsidian + plugin ──┘              ├── server ── vaults (files + git history)
                                    │          └─ database (vaults, tokens)
 Claude (MCP connector) ── /mcp ────┘
 You (browser) ─────────── /admin ──┘
```

## Quick start

**1. The server.** Save this as `compose.yml`:

```yaml
services:
  rock-sync:
    image: ghcr.io/kovalevtech/obsidian-rock-sync:latest  # better: a version
    environment:
      INIT_VAULT_NAME: notes
      INIT_VAULT_CODE: ${INIT_VAULT_CODE:?pick 6 digits and put them in .env}
    volumes:
      - vaults:/vaults
      - db:/db
    ports:
      - 127.0.0.1:9292:9292
volumes:
  vaults:
  db:
```

```sh
echo "INIT_VAULT_CODE=$(LC_ALL=C tr -dc 0-9 < /dev/urandom | head -c 6)" > .env
docker compose up -d
```

This creates the vault `notes` and a connection code for its first device. The server now answers on this machine only; to reach it from your other devices, see [Deployment](docs/deployment.md).

**2. The plugin.** Install **Rock Sync** from Community plugins and enable it ([not listed yet?](docs/plugin.md#installing)).

**3. Connect.** In the plugin's settings, enter the server's URL and the code from `.env`, **Connect**, check the summary and **Save**. The code works for that first device only; for the next ones, use the [admin panel](docs/admin.md#device-tokens).

## Network use

The plugin needs a Rock Sync server, which you run yourself. It sends your vault's files to that server, and only that server, because that's how they reach your other devices. There's no account, no telemetry and, by default, no third-party service.

If you turn on [MCP](docs/mcp.md) on your server, Claude (Anthropic) can read and write the folders you grant there; the plugin itself is not involved.

## Documentation

| Page | What it covers |
|---|---|
| [Deployment](docs/deployment.md) | How it makes sense to run it: network, proxy, storage, backups, updates |
| [Container](docs/container.md) | The Docker image: every setting, volumes, users, why it won't start |
| [Plugin](docs/plugin.md) | Using the plugin: conflicts, deletions, first sync, limits |
| [Admin panel](docs/admin.md) | Managing vaults and tokens in the browser |
| [MCP](docs/mcp.md) | Giving Claude access to chosen folders |
| [Security](docs/security.md) | Tokens, what's stored where, what isn't protected |
| [Storage](docs/storage.md) | How vaults and history are kept on disk |
| [API](docs/api.md) | The sync API, for writing another client |
| [Development](docs/development.md) | Running from source, tests, releases |

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): free for personal and other
noncommercial use. Any commercial use, including use inside a company,
requires a separate license: <contact>.

## Contributing

Issues are welcome. Pull requests are not accepted.
