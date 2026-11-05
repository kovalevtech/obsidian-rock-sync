// Mixed into the plugin (see main.js): conflicts' state and lifecycle — working copies, entering / re-merging /
// resolving a conflict, the conflict view's tabs.
// A conflict lives in a working copy, never in the note: the note keeps my text (clean markdown, indexed as usual)
// and isn't pushed; the working copy is the server's 3-way merge with git's conflict markers, in the plugin folder.
// It's edited in ConflictView, an own CodeMirror editor without Obsidian's markdown: markers hidden, each block a card
// (server lines over my lines, or one Result after the separator was deleted) with its buttons. No markers left →
// the working copy becomes the note and is pushed.

import { Notice } from 'obsidian';
import { settings } from '../settings.js';
import { debug } from '../log.js';
import { encodePath } from '../paths.js';
import { fileUrl, contentTypeOf, request, savedAtOf } from '../api.js';
import { hasMarkers, wholeFileConflict } from './blocks.js';
import { ConflictView, CONFLICT_VIEW } from './view.js';

const AUTO_PUSH_DELAY = 5000; // ms between deciding the last block and the push; Undo is offered meanwhile
const REMOTE_POLL_INTERVAL = 15000; // ms; while a conflict view is open, check whether the server version changed

class ConflictStore {
  registerConflictOps() {
    this.queue.register('resolve', (path, signal) => this.pushItem(path, signal, { resolve: true }));
    this.queue.register('refresh', (path, signal) => this.refreshRemote(path, signal));
  }

  // A merge with conflict markers: it becomes the working copy (the note keeps my text), open views show it.
  // A conflict already open (server changed again, or the resolving push hit a newer version): decisions so far go
  async enterConflict(path, text, conflict) {
    const again = Boolean(this.conflicts[path]);
    this.cancelResolve(path);
    await this.writeWorkingCopy(path, text);
    this.conflicts[path] = { ...conflict, since: this.conflicts[path]?.since ?? new Date().toISOString() };
    await this.saveState();
    this.treeMarks.render();
    debug('conflict', path, this.conflicts[path]);
    for (const view of this.conflictViewsOf(path)) await view.load();
    this.showConflict(path);
    new Notice(again
      ? `Rock Sync: server version of ${path} changed, conflict merged again (earlier decisions reset)`
      : `Rock Sync: conflict in ${path}`);
  }

  // Server version changed since the merge: merge my text (the note) against it again
  async refreshRemote(path, signal) {
    const conflict = this.conflicts[path];
    const file = this.app.vault.getAbstractFileByPath(path);
    if (!conflict || !file) return debug('refresh skipped, no conflict or file', path);

    const res = await request({
      url: fileUrl(path),
      headers: conflict.serverHash ? { 'If-None-Match': conflict.serverHash } : {},
      throw: false,
      signal,
    });
    if (res.status === 304) return debug('remote unchanged', path);
    // Gone on the server: deleted or renamed on another device — the manifest tells which
    if (res.status === 404) {
      debug('conflict gone on the server: checking the manifest', path);
      return this.queue.enqueue('manifest');
    }
    if (res.status !== 200) return console.warn('rock-sync: refresh failed', path, res.status);
    if (res.headers['etag'] === conflict.serverHash) return debug('remote unchanged', path);

    const mine = await this.app.vault.readBinary(file);
    let merge = { status: 412 }; // no base: the whole file as one block
    if (conflict.base) {
      merge = await request({
        url: `${settings.endpoint}/merge/${encodePath(path)}`,
        method: 'POST',
        contentType: contentTypeOf(path),
        body: mine,
        headers: { 'If-Match': conflict.base },
        throw: false,
        signal,
      });
      // Only 412 means "nothing to merge against"; anything else (old server, 5xx) must not become a whole-file block
      if (![200, 409, 412].includes(merge.status)) return console.warn('rock-sync: merge failed', path, merge.status);
    }
    const merged = merge.status === 200 || merge.status === 409;
    const server = merged ? merge : res;
    const updated = { serverHash: server.headers['etag'], savedAt: savedAtOf(server), base: merged ? conflict.base : null };
    // 200: merged cleanly, no markers: the conflict view schedules the resolving push
    const text = merged
      ? new TextDecoder().decode(merge.arrayBuffer)
      : wholeFileConflict(new TextDecoder().decode(res.arrayBuffer), new TextDecoder().decode(mine), updated.savedAt);
    debug('server version changed during conflict, merged again', path, { old: conflict.serverHash, new: updated.serverHash });
    await this.enterConflict(path, text, updated);
  }

  // Working copies live in the plugin folder (never a vault file: not indexed, not synced), mirroring the note's path
  workingCopyFile(path) {
    return `${this.manifest.dir}/conflicts/${path}`;
  }

  async readWorkingCopy(path) {
    const file = this.workingCopyFile(path);
    return (await this.app.vault.adapter.exists(file)) ? this.app.vault.adapter.read(file) : null;
  }

  async writeWorkingCopy(path, text) {
    const { adapter } = this.app.vault;
    const file = this.workingCopyFile(path);
    const parts = file.split('/');
    for (let i = 1; i < parts.length; i++) {
      const dir = parts.slice(0, i).join('/');
      if (!(await adapter.exists(dir))) await adapter.mkdir(dir);
    }
    await adapter.write(file, text);
  }

  async removeWorkingCopy(path) {
    const file = this.workingCopyFile(path);
    if (await this.app.vault.adapter.exists(file)) await this.app.vault.adapter.remove(file);
  }

  // Working copy lost (deleted by hand, a crash mid-write): merge again, the note still has my text
  recoverWorkingCopy(path) {
    debug('working copy missing, merging again', path);
    this.conflicts[path].serverHash = null;
    this.queue.enqueue('refresh', path);
  }

  // Resolved, or ended by a deletion on another device (notice says so)
  async clearConflict(path, notice = `Rock Sync: resolved ${path}`) {
    delete this.conflicts[path];
    this.cancelResolve(path);
    await this.saveState();
    await this.removeWorkingCopy(path);
    this.treeMarks.render();
    for (const view of this.conflictViewsOf(path)) await this.closeConflictView(view.leaf, path);
    debug('conflict closed', path);
    new Notice(notice);
  }

  // The note was renamed on another device (and here, already): its conflict, working copy and tabs follow.
  // A pending auto-push is dropped; the reloaded view schedules it again
  async moveConflict(from, to) {
    for (const view of this.conflictViewsOf(from)) await view.flush();
    this.cancelResolve(from);
    const text = await this.readWorkingCopy(from);
    this.conflicts[to] = this.conflicts[from];
    delete this.conflicts[from];
    await this.saveState();
    if (text !== null) await this.writeWorkingCopy(to, text); // missing: the view's load merges again
    await this.removeWorkingCopy(from);
    this.treeMarks.render();
    for (const view of this.conflictViewsOf(from)) await view.leaf.setViewState({ type: CONFLICT_VIEW, state: { path: to } });
    debug('conflict moved', from, '->', to);
  }

  // Conflicts from when markers were written into the note: put my text (the copy kept by hash) back into the note;
  // the refresh after this merges again into a working copy
  async migrateLegacyConflicts() {
    const { adapter } = this.app.vault;
    for (const [path, c] of Object.entries(this.conflicts)) {
      if (!('mine' in c)) continue;
      const copy = `${this.manifest.dir}/conflicts/${c.mine}`;
      const file = this.app.vault.getAbstractFileByPath(path);
      if (file && c.mine && (await adapter.exists(copy))) await this.writeNote(file, await adapter.read(copy));
      else console.warn('rock-sync: legacy conflict without my copy, note left as is', path);
      this.conflicts[path] = { serverHash: null, savedAt: c.savedAt, base: c.base ?? this.base[path] ?? null, since: new Date().toISOString() };
      if (c.mine && (await adapter.exists(copy))) await adapter.remove(copy);
      debug('legacy conflict migrated', path);
    }
    await this.saveState();
  }

  async writeNote(file, text) {
    this.ownWrites.add(file.path);
    try {
      await this.app.vault.modify(file, text);
    } finally {
      window.setTimeout(() => this.ownWrites.delete(file.path), 1000); // the modify event may come a bit later
    }
  }

  conflictViewsOf(path) {
    return this.app.workspace.getLeavesOfType(CONFLICT_VIEW).map((leaf) => leaf.view)
      .filter((view) => view instanceof ConflictView && view.path === path);
  }

  // Tabs showing the note switch to its conflict view. By view state, not leaf.view: on file-open, and for tabs not
  // loaded yet after a restart, the view doesn't have the file yet
  showConflict(path) {
    for (const leaf of this.app.workspace.getLeavesOfType('markdown')) {
      const { state } = leaf.getViewState();
      if (state?.file === path) leaf.setViewState({ type: CONFLICT_VIEW, state: { path } });
    }
  }

  async closeConflictView(leaf, path) {
    if (this.conflicts[path]) return this.recoverWorkingCopy(path); // not resolved: don't bounce back and forth
    await leaf.setViewState({ type: 'markdown', state: { file: path } });
  }

  // No blocks left in a working copy: push after a delay with Undo (cancels, and undoes the last edit — the
  // decision — in the conflict view). Edits during the delay don't restart it.
  scheduleResolve(path) {
    if (this.resolveTimers.has(path) || !this.conflicts[path]) return;
    const name = path.split('/').pop();
    const textOf = (s) => `All conflicts in ${name} decided, pushing in ${s}\u00a0s`;
    let left = AUTO_PUSH_DELAY / 1000;
    let label;
    // Text and button side by side: the text wraps on its own, the button stays whole at the right
    const notice = new Notice(createFragment((f) => {
      const row = f.createDiv({ cls: 'rock-sync-notice-row' });
      label = row.createSpan({ text: textOf(left) });
      row.createEl('button', { text: 'Undo' }).addEventListener('click', () => {
        this.cancelResolve(path);
        this.conflictViewsOf(path)[0]?.undo();
      });
    }), AUTO_PUSH_DELAY);
    // The seconds count down
    const tick = window.setInterval(() => label.setText(textOf(Math.max(--left, 1))), 1000);
    const timer = window.setTimeout(() => {
      window.clearInterval(tick);
      this.resolveTimers.delete(path);
      this.resolve(path);
    }, AUTO_PUSH_DELAY);
    this.resolveTimers.set(path, { timer, tick, notice });
  }

  cancelResolve(path) {
    const pending = this.resolveTimers.get(path);
    if (!pending) return;
    window.clearTimeout(pending.timer);
    window.clearInterval(pending.tick);
    pending.notice.hide();
    this.resolveTimers.delete(path);
  }

  // The working copy becomes the note, then the push over the server version it was merged against
  async resolve(path) {
    for (const view of this.conflictViewsOf(path)) await view.flush();
    const text = await this.readWorkingCopy(path);
    const file = this.app.vault.getAbstractFileByPath(path);
    if (!this.conflicts[path] || text === null || !file || hasMarkers(text)) return debug('resolve skipped', path);
    await this.writeNote(file, text);
    this.queue.enqueue('resolve', path);
  }
}

export { ConflictStore, REMOTE_POLL_INTERVAL };
