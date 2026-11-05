// Mixed into the plugin (see main.js): paths changing here and there — local renames / deletions sent to the server
// (ops delete, move), deletions from other devices waiting for Delete / Keep (`deleted` marks), and the lock on files
// with an open conflict or stubs (too large for this device)
import { Notice, TFolder } from 'obsidian';
import { settings } from './settings.js';
import { debug } from './log.js';
import { isKeep, keepOf, folderOfKeep, syncable, encodePath } from './paths.js';
import { fileUrl, request, savedAtOf } from './api.js';

export default class Files {
  registerFileOps() {
    this.queue.register('delete', (path, signal) => this.deleteItem(path, signal));
    this.queue.register('move', (path, signal, to) => this.failingFor(to, signal, () => this.moveItem(path, to, signal)));
  }

  // Local renames / deletions → queue. Folders as their `.keep`. Skipped: what we apply for the server ourselves
  registerFileEvents() {
    const syncPath = (f, path = f.path) => (f instanceof TFolder ? keepOf(path) : path);
    this.registerEvent(this.app.vault.on('create', (f) => {
      const path = syncPath(f);
      if (syncable(path) && !this.isApplying(f.path)) this.queue.enqueue('push', path);
    }));
    this.registerEvent(this.app.vault.on('delete', (f) => {
      const path = syncPath(f);
      if (!syncable(path) || this.isApplying(f.path)) return;
      this.failed.delete(path);
      delete this.tooLarge[path];
      // A stub deleted outside Obsidian (inside it's refused): never sent, the next check brings it back
      if (this.stubs[path] !== undefined) {
        delete this.stubs[path];
        delete this.base[path];
        this.saveState();
        return this.queue.enqueue('manifest');
      }
      // Waiting for review (first sync): never sent, so nothing to tell the server either
      if (this.review[path]) {
        delete this.review[path];
        this.saveState();
        return this.firstSync.changed();
      }
      // Deleting what was deleted on another device = Delete: nothing left to tell the server
      if (this.deleted[path]) return this.forgetDeleted(path);
      this.queue.enqueue('delete', path);
    }));
    this.registerEvent(this.app.vault.on('rename', (f, oldPath) => {
      const [from, to] = [syncPath(f, oldPath), syncPath(f)];
      if (this.isApplying(f.path) || this.isApplying(oldPath)) return;
      this.failed.delete(from); // the move pushes `to`
      // A stub renamed outside Obsidian (inside it's refused): never sent; the marks follow it, and the next check
      // renames it back (gone on the server at `to`, its server version unchanged at `from`)
      if (this.stubs[from] !== undefined) {
        [this.stubs[to], this.base[to]] = [this.stubs[from], this.base[from]];
        delete this.stubs[from];
        delete this.base[from];
        this.saveState();
        return this.queue.enqueue('manifest');
      }
      if (this.tooLarge[from]) { // still the same file: the mark follows it, nothing is sent
        this.tooLarge[to] = this.tooLarge[from];
        delete this.tooLarge[from];
        this.saveState();
      }
      if (this.review[from]) { // still waits for review: the mark follows, nothing is sent (the next check re-evaluates it)
        if (syncable(to)) this.review[to] = this.review[from];
        delete this.review[from];
        this.saveState();
        return this.firstSync.changed();
      }
      if (this.conflicts[from]) return new Notice(`Rock Sync: ${from} was renamed during its conflict; not synced`);
      if (this.deleted[from]) { // the mark follows the file; still waits for Delete / Keep
        this.deleted[to] = this.deleted[from];
        delete this.deleted[from];
        this.saveState();
        this.treeMarks.render();
        return;
      }
      if (syncable(from) && syncable(to)) this.queue.enqueue('move', from, to);
      else if (syncable(from)) this.queue.enqueue('delete', from); // e.g. renamed to a hidden or ignored name: gone for sync
      else if (syncable(to)) this.queue.enqueue('push', to);
    }));
  }

  // Renaming / deleting a file with an open conflict or a stub (or a folder holding one) is refused: the conflict is
  // keyed by path; a stub stands for a server version this device can't have, Download first. Obsidian has no way to
  // cancel these, so the methods every UI path goes through are wrapped (restored on unload).
  // Not ours: a rename from another device moves the conflict / stub along (applyRemoteRenames)
  blockConflictedFileOps() {
    const holds = (map, f) => Object.keys(map).some((p) => p === f.path || p.startsWith(`${f.path}/`));
    const refusal = (f) => {
      if (!f || this.isApplying(f.path)) return null;
      if (holds(this.conflicts, f)) return 'Rock Sync: resolve the conflict first';
      if (holds(this.stubs, f)) return 'Rock Sync: too large for this device, not downloaded: Download it first';
      return null;
    };
    const wrap = (target, name) => {
      const original = target[name];
      target[name] = function (file, ...args) {
        const reason = refusal(file);
        if (reason) {
          new Notice(reason);
          return Promise.resolve();
        }
        return original.call(this, file, ...args);
      };
      this.register(() => { target[name] = original; });
    };
    wrap(this.app.fileManager, 'renameFile');
    wrap(this.app.fileManager, 'trashFile');
    wrap(this.app.vault, 'rename');
    wrap(this.app.vault, 'delete');
    wrap(this.app.vault, 'trash');
  }

  isApplying(path) {
    return [...this.applying].some((p) => path === p || path.startsWith(`${p}/`));
  }

  // Run a vault change made for the server (a remote rename, a delete decided by the user) without its events
  // coming back as local changes. Paths cover their subtree; dropped a moment later (events may trail the promise)
  async withoutEcho(paths, fn) {
    paths.forEach((p) => this.applying.add(p));
    try {
      await fn();
    } finally {
      window.setTimeout(() => paths.forEach((p) => this.applying.delete(p)), 1000);
    }
  }

  async deleteItem(path, signal) {
    if (this.localFile(path)) return debug('delete skipped, exists again', path);
    const base = this.base[path];
    if (!base) return debug('delete skipped, never synced', path);

    const res = await request({ url: fileUrl(path), method: 'DELETE', headers: { 'If-Match': base }, throw: false, signal });
    if (res.status === 204) {
      debug('deleted', path);
      delete this.base[path];
      return this.saveState();
    }
    // Edited on another device since I last synced it: bring that version back and let me decide again
    if (res.status === 412 && res.headers['etag']) {
      debug('delete refused, edited elsewhere: restoring', path);
      await this.withoutEcho([isKeep(path) ? folderOfKeep(path) : path], () => this.writeLocal(path, res.arrayBuffer));
      delete this.base[path];
      return this.markDeleted(path, { reason: 'edited', serverHash: res.headers['etag'], deletedAt: savedAtOf(res) });
    }
    console.error('rock-sync: delete failed', path, res.status);
    this.status.failed(`Delete of ${path} failed: ${res.status}`);
  }

  async moveItem(from, to, signal) {
    const base = this.base[from];
    if (!base) return this.pushItem(to, signal); // never synced: just a new file

    const res = await request({
      url: `${settings.endpoint}/move/${encodePath(from)}`,
      method: 'POST',
      headers: { Destination: encodePath(to) },
      throw: false,
      signal,
    });
    if (res.status === 204) {
      debug('moved', from, '->', to);
      this.base[to] = base;
      delete this.base[from];
      await this.saveState();
      return this.pushItem(to, signal); // content edited too, here or (merged by the server) there
    }
    // Taken on the server: both sides created that name. Mine goes up as a new file (412 → conflict); the old path
    // is still on the server and goes the normal way
    if (res.status === 409) {
      debug('move target exists on the server', to);
      await this.pushItem(to, signal);
      return this.queue.enqueue('delete', from);
    }
    // Deleted on another device meanwhile: confirm like any deletion from elsewhere
    if (res.status === 404) {
      debug('move source deleted on the server', from);
      delete this.base[from];
      return this.markDeleted(to, { reason: 'remote' });
    }
    console.error('rock-sync: move failed', from, to, res.status);
    this.status.failed(`Rename of ${from} failed: ${res.status}`);
  }

  async markDeleted(path, mark) {
    this.deleted[path] = { ...mark, deletedAt: mark.deletedAt ?? new Date().toISOString() };
    await this.saveState();
    this.treeMarks.render();
    this.bars.render();
    debug('marked deleted', path, this.deleted[path]);
  }

  // The mark is gone without anything to tell the server (deleted locally); a folder takes its contents' marks along
  async forgetDeleted(path) {
    const prefix = isKeep(path) ? `${folderOfKeep(path)}/` : null;
    for (const p of Object.keys(this.deleted)) if (p === path || (prefix && p.startsWith(prefix))) delete this.deleted[p];
    delete this.base[path];
    await this.saveState();
    this.treeMarks.render();
    this.bars.render();
  }

  // Delete: finish the deletion here (and on the server, if it still has my deleted file's newer version).
  // Keep: the file goes (back) up to the server.
  async decideDeleted(path, keep) {
    const mark = this.deleted[path];
    if (!mark) return;
    delete this.deleted[path];
    if (mark.serverHash) this.base[path] = mark.serverHash; // still on the server
    await this.saveState();
    this.treeMarks.render();
    this.bars.render();
    if (keep) return this.queue.enqueue('push', path);
    const file = this.localFile(path);
    if (!file) return mark.serverHash && this.queue.enqueue('delete', path);
    if (mark.serverHash) return this.app.fileManager.trashFile(file); // its delete event sends the DELETE
    await this.withoutEcho([file.path], () => this.app.fileManager.trashFile(file));
    await this.forgetDeleted(path);
  }
}
