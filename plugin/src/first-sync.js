// The first sync after a rebind (another server or vault, or the first one), owned by the plugin: this.firstSync.
// It compares both sides without a base: identical → base, server only → pulled (approved by Save), everything else
// gets a review mark (state `review[path]` = 'local' | 'differs') and is never sent until the user decides here.
// The marks are re-evaluated by every manifest check (decisions.js). Each decision is a queue op; the mark is dropped
// when it runs (until then a manifest check keeps it), then the path is synced the normal way.
import { Notice, TFile } from 'obsidian';
import { settings } from './settings.js';
import { debug } from './log.js';
import { isKeep, folderOfKeep, mergeable } from './paths.js';
import { gitBlobHash } from './hash.js';
import { fileUrl, request, savedAtOf, manifestUrl, readManifest, DEVICE_LIMIT } from './api.js';
import { wholeFileConflict } from './conflicts/blocks.js';
import ReviewModal from './ui/review.js';

export default class FirstSync {
  constructor(plugin) {
    this.plugin = plugin;
    this.app = plugin.app;
    this.modal = null; // the open review modal, re-rendered on changes
  }

  register() {
    const { queue } = this.plugin;
    queue.register('review-push', (path, signal) => this.run(path, signal, () => this.plugin.pushItem(path, signal)));
    queue.register('review-take', (path, signal) => this.run(path, signal, () => this.plugin.pullItem(path, signal)));
    queue.register('review-keep', (path, signal) => this.run(path, signal, () => this.keepMine(path, signal)));
    queue.register('review-merge', (path, signal) => this.run(path, signal, () => this.merge(path, signal)));
    queue.register('review-both', (path, signal) => this.run(path, signal, () => this.keepBoth(path, signal)));
  }

  // The decision's op: the mark goes, then the normal way. Failed (no answer, or paused meanwhile: the queue runs it
  // again): the mark comes back, the choice is still the user's — not a push the normal rules would make of it
  async run(path, signal, act) {
    const kind = this.plugin.review[path];
    if (!kind) return debug('review action skipped, no mark (decided or gone)', path);
    delete this.plugin.review[path];
    await this.plugin.saveState();
    this.changed();
    try {
      await act();
    } catch (e) {
      this.plugin.review[path] = kind;
      delete this.plugin.base[path]; // Keep mine set it
      await this.plugin.saveState();
      this.changed();
      throw e;
    }
  }

  // Server version of a path as of the last manifest (null: not there); fetched when this session hasn't seen one
  async serverHash(path, signal) {
    if (!this.plugin.remote) {
      const res = await request({ url: manifestUrl(settings.endpoint), signal });
      ({ remote: this.plugin.remote, sizes: this.plugin.sizes } = readManifest(res.json));
    }
    return this.plugin.remote[path] ?? null;
  }

  // Keep mine over the server version: as if it had been synced, then edited here — PUT with If-Match = that version
  // (changed since: the server merges / 409 / 412 like any push)
  async keepMine(path, signal) {
    const hash = await this.serverHash(path, signal);
    if (hash) this.plugin.base[path] = hash;
    await this.plugin.pushItem(path, signal);
  }

  // One whole-file block, server version against mine (nothing to merge from: no base): the conflict view decides
  async merge(path, signal) {
    const file = this.app.vault.getAbstractFileByPath(path);
    if (!(file instanceof TFile)) return;
    const res = await request({ url: fileUrl(path), throw: false, signal });
    if (res.status === 404) return this.plugin.queue.enqueue('manifest'); // gone meanwhile: it's only here now
    if (res.status !== 200) throw new Error(`rock-sync: review merge: GET ${path} → ${res.status}`);
    const conflict = { serverHash: res.headers['etag'], savedAt: savedAtOf(res), base: null };
    const mine = new TextDecoder().decode(await this.app.vault.readBinary(file));
    await this.plugin.enterConflict(path, wholeFileConflict(new TextDecoder().decode(res.arrayBuffer), mine, conflict.savedAt), conflict);
  }

  // Non-mergeable: the server version takes the path, mine becomes a conflict copy (as after a 412 on push)
  async keepBoth(path, signal) {
    const file = this.app.vault.getAbstractFileByPath(path);
    if (!(file instanceof TFile)) return;
    const res = await request({ url: fileUrl(path), throw: false, signal });
    if (res.status === 404) return this.plugin.queue.enqueue('manifest');
    if (res.status !== 200) throw new Error(`rock-sync: review keep both: GET ${path} → ${res.status}`);
    await this.plugin.copies.keepBoth(path, await gitBlobHash(await this.app.vault.readBinary(file)), res);
  }

  // The choices for a marked path: { label: () => void }
  actionsOf(path) {
    const enqueue = (op) => () => this.plugin.queue.enqueue(op, path);
    switch (this.plugin.review[path]) {
      case 'local': return { Push: enqueue('review-push') };
      case 'differs': return {
        'Take server': enqueue('review-take'),
        'Keep mine': enqueue('review-keep'),
        // Both need the server version here: not when it's too large for this device (Take server makes a stub)
        ...(this.plugin.sizes[path] > DEVICE_LIMIT ? {}
          : mergeable(path) ? { Merge: enqueue('review-merge') } : { 'Keep both': enqueue('review-both') }),
      };
      default: return {};
    }
  }

  // { local: [...], differs: [...] }, sorted
  list() {
    const lists = { local: [], differs: [] };
    for (const [path, kind] of Object.entries(this.plugin.review)) lists[kind]?.push(path);
    for (const list of Object.values(lists)) list.sort();
    return lists;
  }

  label(path) {
    return isKeep(path) ? `${folderOfKeep(path)}/` : path;
  }

  // A mark set, moved or dropped
  changed() {
    this.plugin.treeMarks.render();
    this.plugin.bars.render();
    this.modal?.render();
  }

  // After the first sync's manifest check: what waits for review, if anything
  done() {
    const { local, differs } = this.list();
    if (!local.length && !differs.length) return new Notice('Rock Sync: first sync done, everything matches the server');
    const notice = new Notice(`Rock Sync: first sync done. ${local.length} only here, ${differs.length} different from the `
      + 'server: not synced until you review them (click)', 0);
    (notice.containerEl ?? notice.noticeEl).addEventListener('click', () => this.openModal());
  }

  openModal() {
    new ReviewModal(this.plugin).open();
  }
}
