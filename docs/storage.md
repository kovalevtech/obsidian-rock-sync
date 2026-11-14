# Storage

The server keeps two things, in two separate directories: the vaults and a small database. Both are ordinary files you can inspect, copy and back up.

```
/vaults                     VAULTS_DIR
  <vault>/
    tree/                   the vault's current files, plain
    repo.git/               git history, kept outside tree
    vault.lock              writes to the vault, one at a time across server processes
/db                         DB_DIR
  vault-sync.db             SQLite: vaults and tokens (+ -wal, -shm next to it)
  vault-sync.db.lock        migrations, new vaults, connection codes: one process at a time
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

### Paths

A vault holds only paths that pass one rule. It's the same for the sync API and MCP, and it's checked before anything is read or written. A path is refused if it:

- has a segment starting with a dot (`.obsidian`, `.git`, `.gitignore`, `.gitattributes`, `.GIT`, …), except a folder's `.keep`;
- has an empty, `.` or `..` segment, such as a leading, trailing or doubled slash;
- contains a control character (NUL, a line break, …) or a backslash;
- starts with `~`;
- has a segment named `git~1` (the short Windows name of `.git`);
- has a segment over 255 bytes, or is over 1024 bytes as a whole;
- isn't valid UTF-8.

The sync API answers such a path with `400`, MCP with an error (a hidden one reads as not found there). Other characters, including `:`, `*`, `[`, `]` and a leading `-`, are ordinary parts of a name. The plugin never syncs hidden paths, so a vault it fills never holds one.

Git runs isolated from the vault. Files are stored and committed with git's plumbing commands, never through a work tree. A `.gitignore`, `.gitattributes` or nested `.git` folder in `tree/` changes nothing: git stores exactly the bytes a client sent, runs no hooks or filters from the vault, and reads every path literally. `tree/` is updated only after the commit succeeds, so a failed write leaves `tree/` and the history as they were.

#### Cleaning up refused paths

A vault from before this rule, or a file put into `tree/` by hand, may hold refused paths. The server leaves them as they are. At startup it logs one line per such vault with their number and the first few:

```
vault-sync: vault notes holds 2 path(s) the server refuses, left as they are (see docs/storage.md, cleaning up): ".gitignore", "Archive/.git/"
```

The sync API and MCP answer these paths with `400`, so remove them by hand. Stop the server first, then, where the server runs (in its container: `docker exec -it <container> sh`):

```sh
cd /vaults/<vault>
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_LITERAL_PATHSPECS=1
git --git-dir=repo.git read-tree HEAD    # the index = the last commit
# For each path that's in the history (listed by: git --git-dir=repo.git ls-tree -r --name-only HEAD)
git --git-dir=repo.git --work-tree=tree rm -q -r --cached -- '<path>'
# Then one commit for all of them
git --git-dir=repo.git --work-tree=tree -c user.name=sync -c user.email=sync@localhost commit -q -m 'DELETE <path>'
# And each path from tree/ (or move it elsewhere to keep it)
rm -rf 'tree/<path>'
```

Paths that are in `tree/` only, such as a folder logged with a trailing slash, need just the last step. Older versions stay in the history either way. Devices pick up the commit like any other.

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
| `history_events`, `history_entries`, `history_state` | The admin's [history](admin.md#history) index: a cache of each vault's git history, rebuilt when missing. Safe to empty: `DELETE FROM history_state; DELETE FROM history_entries; DELETE FROM history_events;` |

No tokens are stored, only their hashes. A revoked token keeps its row. Connection codes are stored as they are: [why](security.md#connection-codes).

## Backups

See [Deployment](deployment.md#backups).
