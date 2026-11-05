// Conflict copies: keep both for files the server can't merge. Owned by the plugin (`plugin.copies`).
// A copy is recognized by name alone (`X (copy).ext` while `X.ext` exists), on every device: no state of its own
import { Notice, TFile } from 'obsidian';
import { debug } from './log.js';
import { syncable, copyOrigin, copyPath } from './paths.js';
import { gitBlobHash } from './hash.js';

export default class Copies {
  constructor(plugin) {
    this.plugin = plugin;
    this.app = plugin.app;
  }

  // The original of a conflict copy, or null (not named like one, or its original is gone)
  originOf(path) {
    const origin = copyOrigin(path);
    return origin && this.app.vault.getAbstractFileByPath(origin) instanceof TFile ? origin : null;
  }

  list() {
    return this.app.vault.getFiles().map((f) => f.path).filter((p) => syncable(p) && this.originOf(p));
  }

  // Push of a non-mergeable file refused with 412 + the server version (changed here and elsewhere): mine moves to a
  // copy and goes up as a new file, the server version takes the path. Links aren't rewritten (vault.rename).
  // Returns whether it did (not when the file changed meanwhile)
  async keepBoth(path, sentHash, res) {
    const { plugin } = this;
    const { vault } = this.app;
    const file = vault.getAbstractFileByPath(path);
    // Changed while the request was in flight: its queued push tries again
    if (!(file instanceof TFile) || (await gitBlobHash(await vault.readBinary(file))) !== sentHash) {
      debug('keep both skipped, the file changed meanwhile; left for its queued push', path);
      return false;
    }
    const copy = copyPath(path, (p) => Boolean(vault.getAbstractFileByPath(p) || plugin.base[p]));
    debug('keep both', path, '->', copy, { server: res.headers['etag'] });
    // Neither the rename nor the write is a local edit to send
    await plugin.withoutEcho([path, copy], async () => {
      await vault.rename(file, copy);
      await plugin.writeLocal(path, res.arrayBuffer);
    });
    plugin.base[path] = res.headers['etag'];
    plugin.saveState();
    plugin.queue.enqueue('push', copy);
    plugin.treeMarks.render();
    plugin.bars.render();
    new Notice(`Rock Sync: ${path} was changed here and on another device. Yours is kept as ${copy}`);
    return true;
  }

  // The copy's content becomes the original: written here, its modify pushes it (If-Match = base of the original —
  // changed on the server again → keep both again); the copy goes to the trash, its delete event removes it there
  async replaceOriginal(path) {
    const origin = this.originOf(path);
    const copy = this.app.vault.getAbstractFileByPath(path);
    if (!origin || !(copy instanceof TFile)) return;
    await this.plugin.writeLocal(origin, await this.app.vault.readBinary(copy));
    await this.app.fileManager.trashFile(copy);
  }

  async deleteCopy(path) {
    const copy = this.app.vault.getAbstractFileByPath(path);
    if (copy instanceof TFile) await this.app.fileManager.trashFile(copy);
  }
}
