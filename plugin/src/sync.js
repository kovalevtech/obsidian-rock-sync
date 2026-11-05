// Mixed into the plugin (see main.js): content sync — push (PUT with If-Match; the server merges), pull, and the
// manifest check that decides what to push / pull / delete / rename
import { Notice, TFolder } from 'obsidian';
import { settings } from './settings.js';
import { debug } from './log.js';
import { isKeep, keepOf, folderOfKeep, syncable, isMarkdown, mergeable } from './paths.js';
import { gitBlobHash, EMPTY_HASH } from './hash.js';
import { fileUrl, contentTypeOf, request, savedAtOf, manifestUrl, readManifest, DEVICE_LIMIT } from './api.js';
import { exactText } from './text.js';
import { wholeFileConflict } from './conflicts/blocks.js';
import { decide } from './decisions.js';

export default class Sync {
  registerSyncOps() {
    this.queue.register('push', (path, signal) => this.failingFor(path, signal, () => this.pushItem(path, signal)));
    this.queue.register('pull', (path, signal) => this.pullItem(path, signal));
    // A stub's Download: the server version whatever its size (may be too much for this device: the user's call)
    this.queue.register('download', (path, signal) => this.pullItem(path, signal, { force: true }));
    this.queue.register('manifest', (path, signal) => this.checkManifest(signal));
  }

  // Content is read when the item runs, not when queued: autosaves during a slow request collapse into one push
  // resolve: push the decided note over the server version it was merged against, even if unchanged
  async pushItem(path, signal, { resolve = false } = {}) {
    const file = this.localFile(path);
    // Gone: renamed or deleted since it was queued (its move / delete is queued too)
    if (!file || !syncable(path)) return debug('push skipped, file gone or not syncable', path);
    if (resolve && !this.conflicts[path]) return debug('resolve skipped, no conflict', path);
    // Only an explicit resolve tells the server how the conflict ended
    if (!resolve && this.conflicts[path]) return debug('push skipped, in conflict', path);
    if (this.deleted[path]) return debug('push skipped, deleted on another device: waits for Delete / Keep', path);
    if (this.review[path]) return debug('push skipped, waits for review (first sync)', path);

    if (this.isTooLarge(file)) return debug('push skipped, refused as too large and unchanged since', path);
    if (this.stubs[path] !== undefined) return debug('push skipped, a stub for a server version too large for this device', path);
    // Reading it would crash the mobile app: sent only from devices that can, unless known unchanged (hash cache)
    if (file.stat?.size > DEVICE_LIMIT) {
      if (this.cachedHash(file) === this.base[path]) return debug('push skipped, unchanged since base', path);
      return debug('push skipped, too large for this device', path);
    }

    const body = isKeep(path) ? new ArrayBuffer(0) : await this.app.vault.readBinary(file);
    const base = resolve ? this.conflicts[path].serverHash : this.base[path];
    const hash = await gitBlobHash(body);
    // Nothing new; also stops a pull (or applied merge) bouncing back as a push
    if (!resolve && base && hash === base) {
      this.failed.delete(path); // back to what the server has: nothing left to send
      return debug('push skipped, unchanged since base', path);
    }
    debug(resolve ? 'resolving' : 'pushing', path, { bytes: body.byteLength, base: base ?? 'none (create)' });

    const res = await request({
      url: fileUrl(path),
      method: 'PUT',
      contentType: contentTypeOf(path),
      body,
      headers: base ? { 'If-Match': base } : { 'If-None-Match': '*' },
      throw: false,
      signal,
    });

    this.failed.delete(path); // an answer; set again below if it's a refusal
    delete this.tooLarge[path];
    if (res.status === 204) {
      debug('pushed', path, { base: base ?? 'none', new: res.headers['etag'] });
      this.base[path] = res.headers['etag'];
      if (resolve) await this.clearConflict(path);
      return this.saveState();
    }
    // Resolve + server changed again but merged cleanly: the conflict is over too
    if (res.status === 200) {
      if (resolve) await this.clearConflict(path);
      return this.applyMerged(file, body, res);
    }
    // 409: merged with conflicts, the body has markers. 412: nothing to merge against, the body is the server version
    if (res.status === 409 || (res.status === 412 && res.headers['etag'])) {
      if (isKeep(path)) return console.warn('rock-sync: folder marker refused', path, res.status); // all are empty
      // Not mergeable (412 + the server version): keep both, mine as a conflict copy
      if (!mergeable(path)) return this.copies.keepBoth(path, hash, res);
      // Edited while the request was in flight: the working copy wouldn't have the edit; its queued push merges again
      if (new TextDecoder().decode(body) !== await this.app.vault.read(file)) {
        return debug('conflict, but the note changed meanwhile; left for its queued push', path);
      }
      const conflict = { serverHash: res.headers['etag'], savedAt: savedAtOf(res), base: res.status === 409 ? base : null };
      const text = res.status === 409
        ? new TextDecoder().decode(res.arrayBuffer)
        : wholeFileConflict(new TextDecoder().decode(res.arrayBuffer), new TextDecoder().decode(body), conflict.savedAt);
      return this.enterConflict(path, text, conflict);
    }
    // Gone on the server: deleted or renamed on another device — the manifest tells which
    if (res.status === 412) {
      debug('push refused, gone on the server: checking the manifest', path);
      return this.queue.enqueue('manifest');
    }
    // Over the server's size limit: marked, never read or sent again while it stays this file
    if (res.status === 413) {
      this.tooLarge[path] = [file.stat.mtime, file.stat.size];
      this.saveState();
      new Notice(`Rock Sync: ${path} is larger than the server accepts; not synced`);
      return console.warn('rock-sync: push refused, too large', path, { bytes: body.byteLength });
    }
    this.failed.add(path);
    console.error('rock-sync: push failed', path, res.status);
    this.status.failed(`Upload of ${path} failed: ${res.status}`);
  }

  // No answer after all retries (offline, server down): path marked failed, pushed again on its next change or
  // manifest check. Not when aborted: the queued copy of the item runs again anyway
  async failingFor(path, signal, run) {
    try {
      await run();
    } catch (e) {
      if (!signal.aborted) this.failed.add(path);
      throw e;
    }
  }

  // Refused as too large (413), and still the same file (mtime + size): not read, hashed or sent
  isTooLarge(file) {
    const mark = this.tooLarge[file.path];
    return Boolean(mark) && mark[0] === file.stat?.mtime && mark[1] === file.stat?.size;
  }

  // The vault file behind a sync path: a folder for `.keep`, else a file
  localFile(path) {
    const f = this.app.vault.getAbstractFileByPath(isKeep(path) ? folderOfKeep(path) : path);
    if (!f) return null;
    return isKeep(path) === f instanceof TFolder ? f : null;
  }

  // A sync path's content into the vault (folders: created), parents created as needed
  async writeLocal(path, bytes) {
    const target = isKeep(path) ? folderOfKeep(path) : path;
    const dir = isKeep(path) ? target : path.split('/').slice(0, -1).join('/');
    if (dir && !this.app.vault.getAbstractFileByPath(dir)) await this.app.vault.createFolder(dir);
    if (isKeep(path)) return;
    const file = this.app.vault.getAbstractFileByPath(path);
    // Notes as text: an open editor keeps its cursor. Not exact UTF-8: as bytes, so the file stays the server's version
    const text = isMarkdown(path) ? exactText(bytes) : null;
    if (text !== null) {
      if (file) await this.app.vault.modify(file, text);
      else await this.app.vault.create(path, text);
    } else if (file) await this.app.vault.modifyBinary(file, bytes);
    else await this.app.vault.createBinary(path, bytes);
  }

  // Server merged our push with a newer remote version and returned the result
  async applyMerged(file, sent, res) {
    const sentText = new TextDecoder().decode(sent);
    const mergedText = exactText(res.arrayBuffer) ?? new TextDecoder().decode(res.arrayBuffer);
    let applied = false;

    await this.app.vault.process(file, (current) => {
      // Edited while the request was in flight: keep the edit, its queued push merges again
      if (current !== sentText) return current;
      applied = true;
      return mergedText;
    });

    if (!applied) return debug('merged, but file changed meanwhile; left for queued push', file.path);

    // The push queued by this write's modify runs after us, sees hash === base and skips
    debug('merged', file.path, { new: res.headers['etag'] });
    this.base[file.path] = res.headers['etag'];
    await this.saveState();
  }

  // force: download even what's too large for this device (a stub's Download)
  async pullItem(path, signal, { force = false } = {}) {
    // Local side of a conflict is only replaced by hand
    if (this.conflicts[path]) return debug('pull skipped, in conflict', path);
    if (!force && this.sizes[path] > DEVICE_LIMIT) return this.writeStub(path);
    debug('pulling', path, { base: this.base[path] ?? 'none' });

    const res = await request({ url: fileUrl(path), signal });
    // Not a local edit: no push queued behind the other pulls (it would only find hash = base, but the path would look
    // unsynced meanwhile). A file's parent folders created here still send their `.keep`: harmless, identical content
    await this.withoutEcho([isKeep(path) ? folderOfKeep(path) : path], () => this.writeLocal(path, res.arrayBuffer));

    this.base[path] = res.headers['etag'];
    // Known as written: a file too large for this device is never read here, its hash comes from this cache entry
    const stat = isKeep(path) ? null : await this.app.vault.adapter.stat(path);
    if (stat) this.hashes[path] = [stat.mtime, stat.size, this.base[path]];
    if (this.stubs[path] !== undefined) {
      delete this.stubs[path];
      this.treeMarks.render();
      this.bars.render();
    }
    await this.saveState();
    debug('pulled', path, { bytes: res.arrayBuffer.byteLength, base: this.base[path] });
  }

  // The server version is too large for this device (DEVICE_LIMIT): an empty file stands in for it (base = that
  // version), nothing is downloaded. The stub follows later server versions without a download (checkManifest)
  async writeStub(path) {
    const file = this.localFile(path);
    if (!file || file.stat.size > 0) await this.withoutEcho([path], () => this.writeLocal(path, new ArrayBuffer(0)));
    this.stubs[path] = this.sizes[path];
    this.base[path] = this.remote[path];
    await this.saveState();
    this.treeMarks.render();
    this.bars.render();
    debug('stub, too large for this device', path, { bytes: this.sizes[path] });
  }

  // A stub whose server version is gone: nothing here to keep
  async removeStub(path) {
    const file = this.localFile(path);
    if (file) await this.withoutEcho([path], () => this.app.vault.delete(file));
    delete this.stubs[path];
    delete this.base[path];
    debug('stub removed, gone on the server', path);
  }

  // Renames on another device, applied here as renames (open tabs stay): a path gone from the server, unchanged
  // here, and a new one with the same content. A folder at once when its `.keep` and every synced file in it moved to
  // the same relative paths under a new name (all `.keep` share one hash, so folders can't be matched by content).
  // A conflicted note matches by the server version it was merged against (mine may differ) and takes its conflict
  // along. base moves along; the renames' own events are skipped. Mutates local (and the caller's view of base).
  async applyRemoteRenames(local, remote) {
    // What the server had at p, as far as this device knows
    const was = (p) => (this.conflicts[p] ? this.conflicts[p].serverHash : this.base[p]);
    const movableGone = (p) => !remote[p] && local[p] && !this.deleted[p]
      && (this.conflicts[p] ? Boolean(this.conflicts[p].serverHash) : local[p] === this.base[p]);
    const known = [...new Set([...Object.keys(this.base), ...Object.keys(this.conflicts)])];
    const fresh = (p) => remote[p] && !local[p] && !this.base[p];
    const rename = async (from, to, paths) => {
      const target = this.app.vault.getAbstractFileByPath(isKeep(from) ? folderOfKeep(from) : from);
      const dest = isKeep(to) ? folderOfKeep(to) : to;
      const dir = dest.split('/').slice(0, -1).join('/');
      if (dir && !this.app.vault.getAbstractFileByPath(dir)) await this.app.vault.createFolder(dir);
      await this.withoutEcho([target.path, dest], () => this.app.vault.rename(target, dest));
      for (const [a, b] of paths) {
        if (this.base[a]) this.base[b] = this.base[a];
        if (this.stubs[a] !== undefined) this.stubs[b] = this.stubs[a];
        delete this.stubs[a];
        local[b] = local[a];
        delete this.base[a];
        delete local[a];
        if (this.conflicts[a]) await this.moveConflict(a, b);
      }
    };

    for (const goneKeep of known.filter((p) => isKeep(p) && movableGone(p))) {
      const oldDir = folderOfKeep(goneKeep);
      const inside = known.filter((p) => p.startsWith(`${oldDir}/`));
      // An empty folder renamed looks the same as one deleted and another created: left to the normal rules
      if (!inside.some((p) => !isKeep(p))) continue;
      const newKeep = Object.keys(remote).find((k) => isKeep(k) && fresh(k) && inside.every((p) => {
        const moved = `${folderOfKeep(k)}/${p.slice(oldDir.length + 1)}`;
        return movableGone(p) && fresh(moved) && remote[moved] === was(p);
      }));
      if (!newKeep) continue;
      debug('decision: folder renamed on another device', oldDir, '->', folderOfKeep(newKeep));
      await rename(goneKeep, newKeep, inside.map((p) => [p, `${folderOfKeep(newKeep)}/${p.slice(oldDir.length + 1)}`]));
    }

    for (const gone of known.filter((p) => !isKeep(p) && movableGone(p))) {
      const candidates = Object.keys(remote).filter((p) => !isKeep(p) && fresh(p) && remote[p] === was(gone));
      const twins = known.filter((p) => !isKeep(p) && movableGone(p) && was(p) === was(gone));
      if (candidates.length !== 1 || twins.length !== 1) continue; // none, or ambiguous: the normal rules
      debug('decision: renamed on another device', gone, '->', candidates[0]);
      await rename(gone, candidates[0], [[gone, candidates[0]]]);
    }
  }

  // A file's hash, cached per device by mtime + size: a manifest check reads only files changed since the last one
  async localHash(file) {
    const cached = this.cachedHash(file);
    if (cached) return cached;
    const { mtime, size } = file.stat;
    const hash = await gitBlobHash(await this.app.vault.readBinary(file));
    this.hashes[file.path] = [mtime, size, hash];
    return hash;
  }

  // The cached hash while the file keeps its mtime + size, else undefined
  cachedHash(file) {
    const [mtime, size, hash] = this.hashes[file.path] ?? [];
    return mtime === file.stat.mtime && size === file.stat.size ? hash : undefined;
  }

  // Too large to read on this device and not known from the hash cache: not synced from here
  tooLargeHere(file) {
    return file.stat.size > DEVICE_LIMIT && !this.cachedHash(file);
  }

  // The local side of a manifest: { local: path -> hash of every syncable file and folder (as its virtual `.keep`),
  // tooLarge: paths left out }. Too large for the server = left out of the comparison altogether (not "gone here":
  // that would delete it there). onProgress(done, total) while hashing; signal stops it (nothing cleaned up then)
  async localManifest({ signal, onProgress } = {}) {
    const local = {};
    const tooLarge = new Set();
    const files = this.app.vault.getFiles().filter((f) => syncable(f.path));
    for (const [i, file] of files.entries()) {
      if (signal?.aborted) throw new Error('local manifest aborted');
      if (this.isTooLarge(file) || this.tooLargeHere(file)) tooLarge.add(file.path);
      else local[file.path] = await this.localHash(file);
      onProgress?.(i + 1, files.length);
    }
    for (const path of Object.keys(this.hashes)) if (!local[path]) delete this.hashes[path]; // gone
    for (const path of Object.keys(this.tooLarge)) if (!tooLarge.has(path)) delete this.tooLarge[path]; // gone or changed
    for (const f of this.app.vault.getAllLoadedFiles()) {
      if (f instanceof TFolder && !f.isRoot() && syncable(keepOf(f.path))) local[keepOf(f.path)] = EMPTY_HASH;
    }
    debug('hashed local files', Object.keys(local).length);
    return { local, tooLarge };
  }

  // Only decides (decisions.js) and enqueues; the actual pulls/pushes run as their own queue items
  async checkManifest(signal) {
    debug('checking manifest');

    const res = await request({ url: manifestUrl(settings.endpoint), signal });
    this.manifestEtag = res.headers['etag']; // the version long polls wait past
    const { remote, sizes } = readManifest(res.json);
    this.remote = remote; // server versions for review actions (Keep mine)
    this.sizes = sizes; // pulls of what's too large for this device write stubs
    const firstSync = this.firstSyncDue;
    debug('manifest', res.json.version, {
      files: Object.keys(res.json.files).length,
      syncable: Object.keys(remote).length,
    });

    const { local, tooLarge } = await this.localManifest({ signal });

    // A stub stands for the server version it was made for: its own content is never compared. Gone here (deleted or
    // renamed outside Obsidian): forgotten, the server version comes back as a stub. An empty file where the server's
    // version is too large for this device (a stub from before a rebind) is one again
    for (const path of Object.keys(this.stubs)) {
      if (local[path] === undefined) {
        delete this.stubs[path];
        delete this.base[path];
      } else local[path] = this.base[path];
    }
    for (const [path, size] of Object.entries(sizes)) {
      if (size <= DEVICE_LIMIT || this.stubs[path] !== undefined || local[path] !== EMPTY_HASH || this.conflicts[path]) continue;
      this.stubs[path] = size;
      this.base[path] = remote[path];
      local[path] = remote[path];
    }

    await this.applyRemoteRenames(local, remote);

    const paths = new Set([...Object.keys(local), ...Object.keys(remote), ...Object.keys(this.base), ...Object.keys(this.review)]);
    for (const path of paths) {
      if (tooLarge.has(path)) continue;
      if (this.stubs[path] !== undefined) {
        if (!remote[path]) {
          await this.removeStub(path);
          continue;
        }
        // Still too large: follows the server's versions, nothing downloaded. Smaller now: the table pulls it (local = base)
        if (sizes[path] > DEVICE_LIMIT) {
          this.base[path] = remote[path];
          this.stubs[path] = sizes[path];
          continue;
        }
      }
      const [action, reason] = decide({
        local: local[path], remote: remote[path], base: this.base[path], conflict: this.conflicts[path], deleted: Boolean(this.deleted[path]),
        review: this.review[path], firstSync,
      });
      if (action === 'review-local' || action === 'review-differs') {
        if (this.review[path] !== action.slice(7)) debug(`decision: ${reason}`, path);
        this.review[path] = action.slice(7); // 'local' | 'differs'
        continue;
      }
      if (this.review[path]) {
        debug('review mark dropped', path, action);
        delete this.review[path];
      }
      if (action === 'none') continue;
      debug('compare', path, { local: local[path] ?? 'missing', remote: remote[path] ?? 'missing', base: this.base[path] ?? 'none' });
      debug(`decision: ${reason}`, path);
      if (action === 'in-sync') this.base[path] = local[path];
      else if (action === 'drop-base') {
        delete this.base[path];
        if (this.conflicts[path]) await this.clearConflict(path, `Rock Sync: ${path} was deleted on another device, conflict closed`);
      } else if (action === 'mark-deleted') {
        delete this.base[path];
        if (this.conflicts[path]) {
          await this.clearConflict(path, `Rock Sync: ${path} was deleted on another device during its conflict; your text is kept here`);
        }
        await this.markDeleted(path, { reason: 'remote' });
      } else if (action === 'push' && sizes[path] > DEVICE_LIMIT && remote[path] !== this.base[path]) {
        // Changed on both sides, and the server's version can't come here (its 412 body alone would crash the app):
        // mine goes up as a conflict copy, a stub takes the path
        const kept = await this.copies.keepBoth(path, local[path], { headers: { etag: remote[path] }, arrayBuffer: new ArrayBuffer(0) });
        if (kept) this.stubs[path] = sizes[path];
      } else this.queue.enqueue(action, path); // refresh, delete, pull, push
    }

    if (firstSync) this.firstSyncDue = false;
    await this.saveState();
    this.firstSync.changed();
    debug('manifest check done, base saved', res.json.version);
    if (firstSync) this.firstSync.done();
  }
}
