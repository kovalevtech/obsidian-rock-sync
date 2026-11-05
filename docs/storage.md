# Storage

The server keeps two things, in two separate directories: the vaults and a small database. Both are ordinary files you can inspect, copy and back up.

```
/vaults                     VAULTS_DIR
  <vault>/
    tree/                   the vault's current files, plain
    repo.git/               git history, kept outside tree
/db                         DB_DIR
  vault-sync.db             SQLite: vaults and tokens (+ -wal, -shm next to it)
```

## Why two directories

The database lists the vaults, so the server can tell that a vault should be there. If a vault in the database has no `repo.git`, or either directory is missing, the server refuses to start instead of treating unmounted storage as a fresh install. It creates the database file when it's missing, but never the directories. See [Container](container.md#why-it-wont-start).

## Vaults

A vault's name is `[a-z0-9-]`, at most 64 characters. `tree/` is the current state as plain files, so you can export a vault by copying that folder.

Every write is its own commit: there are no branches, and commits are never amended, because every version a client has synced must stay reachable as a base for later merges. History grows with every autosave. That's accepted.

| Commit message | Made by |
|---|---|
| `PUT <path>` | A write |
| `MERGE <path>` | A write merged on the server |
| `DELETE <path>` | A delete |
| `RENAME <from> → <to>` | A rename |
| `APPEND <path>` | MCP's `append_file` |

The commit's author says who made it; the committer is always the server (`sync`):

| Client | Git author | Trailer |
|---|---|---|
| A device | `<name> <name@device>` | `Client: plugin=…; obsidian=…; platform=…` |
| An MCP token | `<name> <name@token>` | `Client: mcp` |

To see the history:

```sh
git --git-dir=/vaults/<vault>/repo.git log --oneline --stat
git --git-dir=/vaults/<vault>/repo.git log --format='%an %s%n%b' -- 'Notes/Idea.md'
```

There's no rollback in the API or the plugin yet. To get an old version back, take it from git and write it over the current one.

### What's stored

Every file type goes in git, attachments included, without Git LFS. A file over `MAX_FILE_SIZE` (100 MB by default) is refused. Big files that change often will make the repository grow fast: every version stays.

- **Folders** are empty `<folder>/.keep` files, so empty folders sync too.
- **Merging** is decided per request by `Content-Type` ([API](api.md#put-filespath)). The plugin allows it only for Markdown.
- **Conflicted pushes** are stored as git objects even though nothing is committed, and git drops them after two weeks once they're compacted.

### Compacting

Nothing packs a repository on its own, so every version starts as a separate compressed file. **Compact** in the [admin panel](admin.md#vaults) runs `git gc` in the background. Sync keeps working meanwhile, and committed versions always stay. The gain comes from text files that have many versions; big media barely shrinks.

## Database

SQLite, migrated automatically at startup.

| Table | Holds |
|---|---|
| `vaults` | Names and creation times |
| `devices` | Tokens of both kinds: name, SHA-256 of the token, created, revoked, last seen; a device token's vault |
| `scoped_token_grants` | Which folders a scoped token may reach, and how |
| `pairings` | Active [connection codes](admin.md#device-tokens), each with its vault (and token, for Reconnect), until it's used, expired or cancelled |

No tokens are stored, only their hashes. A revoked token keeps its row. Connection codes are stored as they are: [why](security.md#connection-codes).

## Backups

See [Deployment](deployment.md#backups).
