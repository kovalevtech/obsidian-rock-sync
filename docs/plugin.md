# Plugin

Rock Sync keeps an Obsidian vault in sync with [your server](deployment.md). It works on desktop and mobile and needs Obsidian 1.8.7 or later.

## Installing

In Obsidian: **Settings → Community plugins → Browse**, find **Rock Sync**, install and enable it. Obsidian offers its updates like any other plugin's.

If it isn't listed yet, install it by hand: download `main.js`, `manifest.json` and `styles.css` from the [latest release](https://github.com/kovalevtech/obsidian-rock-sync/releases/latest) into `<vault>/.obsidian/plugins/rock-sync/`, then enable it in Community plugins. Each file carries a build provenance attestation: `gh attestation verify main.js --repo kovalevtech/obsidian-rock-sync` checks that it was built by the release workflow from this repository.

## Connecting

Open the plugin's settings. On top is the sync status, under it **Connection**: the server, the vault and this device's name, with **Edit** and **Remove**. Not connected yet, or after **Edit**:

1. Enter the **Server URL** and a **Connection code**: from the [admin panel](admin.md#device-tokens), which issues it for one vault, or `INIT_VAULT_CODE` for a new server's first device. The admin panel's **connection link** (`https://notes.example.com?code=482913`) holds both: paste it into either field and the plugin fills them. Check the **Device name**: it becomes the author of this device's commits.
2. **Connect.** The code gives this device its own token for that vault.
3. Check the summary: the vault, then `Identical N · only here N · only on the server N · different N`.
4. **Save.**

Nothing moves until you save. The token stays on this device in Obsidian's local storage ([Security](security.md#tokens)). A code works once: **Cancel**, or closing the settings before **Save**, revokes the token it gave.

Connecting to another server or vault starts over with a [first sync](#first-sync), and the old token is revoked. A code for the vault already connected here (the admin panel's **Reconnect**) only replaces the token: it's saved at once, nothing to review.

**Remove** stops syncing this vault and revokes this device's token on the server. The files stay. Not while a conflict is open.

## What syncs

Everything Obsidian indexes, of every file type. Not synced:

- hidden paths, anything with a segment starting with a dot, which includes `.obsidian`;
- `Thumbs.db` and `desktop.ini`;
- files over the [size limits](#size-limits).

The plugin turns on Obsidian's **Detect all file extensions** once on each device, so files of every type show up in the file explorer. If you turn it off again, it stays off.

## When it syncs

Your edits go up as Obsidian saves them. Other devices' changes arrive within seconds through a long poll. It also does a full check at startup, when the app returns to the foreground and when the connection comes back, so edits made offline go up automatically.

## Status

An icon next to the vault's name shows the state (in the ribbon if there's no room for it). Click it to open the settings, where the same state appears with the last sync and the last error, plus **Retry**.

| Icon | Meaning |
|---|---|
| Green cloud with a check | Synced |
| Circular arrows | Syncing |
| Grey crossed-out cloud | Offline, retrying by itself |
| Red cloud with an alert | Error, or sync paused, for example because the token was refused |

## Marks in the file explorer

A dot after a name marks the file and all folders above it. Opening a marked file shows a bar explaining the mark, with what you can do about it.

| Mark | Meaning |
|---|---|
| Red dot | Open [conflict](#conflicts) |
| Yellow dot | [Conflict copy](#conflict-copies) |
| Yellow ring | Waiting for your [review](#first-sync) |
| Grey dot | Not synced: queued, the last upload failed, or too large |
| Grey ring, muted name | [Not on this device](#size-limits): too large |
| Struck through | [Deleted on another device](#deletions) |

## Conflicts

When two devices change a note, the server merges it. You only see a conflict when both changed the same lines.

Your note then keeps your text and stays a clean note, while the conflict opens in its own view, which replaces the note's tabs. It isn't synced until you're done.

Each conflicting block shows **Server** and **Mine**. Choose **Take server**, **Keep mine** or **Both**, or just edit the text and press **Done**. Deleting the separator between the sides turns them into one result. `Cmd/Ctrl+Z` works as usual.

After the last block, the result is pushed in 5 seconds, with an **Undo** in the notice. If the server's version changes again while you work, it's merged again and your choices in the view so far are lost. A conflicted note can't be renamed or deleted until it's resolved. If another device deletes it, the conflict closes, your text stays, and the note is marked as deleted.

## Conflict copies

Only `.md` files can be merged (not `.excalidraw.md`). When any other file changes on both sides, both versions are kept: the server's stays at the path, and yours becomes `<name> (copy).<ext>`, which syncs like any file.

Open the copy to choose **Replace original** or **Delete copy**. To keep both for good, rename the copy. **Review conflict copies** lists them all.

## Deletions

**Nothing is deleted on your device without your confirmation.** When another device deletes a file, yours stays, struck through, with a bar offering **Delete** or **Keep**. Editing it counts as Keep, and deleting it counts as Delete. **Review deletions from other devices** lists them all.

If you delete a file that another device edited in the meantime, it comes back marked "Edited on another device after you deleted it".

Renames sync as renames, and tabs stay open. Links updated by the rename arrive as normal edits.

## First sync

Connecting to a vault never overwrites what you have:

| Situation | What happens |
|---|---|
| Identical on both sides | Nothing to do |
| Only on the server | Downloaded |
| Only here | Marked for review, not sent |
| On both, different | Marked for review, not sent |

A notice counts what's waiting. Decide file by file from the bar, or in bulk with **Review files from first sync**:

- **Only here:** Push.
- **Different:** Take server, Keep mine, or Merge (notes) / Keep both (other files).

## Size limits

- **Server:** `MAX_FILE_SIZE`, 100 MB by default. A bigger file stays here with a grey dot and isn't retried until it changes.
- **Mobile:** 20 MB per file, because larger transfers can run the mobile app out of memory. A bigger server version becomes an empty placeholder with a grey ring. The bar offers **Download**, at your own risk. Placeholders are never uploaded, so they can't damage the server's version. A local file over the limit shows a grey dot and isn't sent from this device.

## Commands

| Command | Does |
|---|---|
| Review deletions from other devices | Lists deleted files |
| Review conflict copies | Lists conflict copies |
| Review files from first sync | Lists files waiting for review |
| Check manifest | Compares with the server right now |

## Troubleshooting

- **Paused, the token was refused:** the token was revoked. **Reconnect** it in the admin panel and connect with that code: same name, same vault, nothing to review.
- **Offline though the server is up:** check the URL from the device's browser (`<server>/health` answers `ok`), then check the [proxy settings](deployment.md#reverse-proxy).
- **Details:** turn on **Debug logging** in the settings and open the developer console (`Cmd+Opt+I` / `Ctrl+Shift+I`). The messages are at the Verbose level, which the console may hide by default.
