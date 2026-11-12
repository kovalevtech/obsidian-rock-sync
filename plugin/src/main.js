import { Notice, Plugin } from 'obsidian';

import { DEFAULT_SETTINGS, SETTINGS_KEY, settings, RockSyncSettingTab } from './settings.js';
import { debug } from './log.js';
import { syncable } from './paths.js';
import { session, clientInfo, retryNow } from './api.js';
import Credentials from './credentials.js';
import FirstSync from './first-sync.js';
import SyncStatus from './status.js';
import StatusIcon from './ui/status-icon.js';
import ReviewModal from './ui/review.js';
import { ConflictView, CONFLICT_VIEW } from './conflicts/view.js';
import { ConflictStore, REMOTE_POLL_INTERVAL } from './conflicts/store.js';
import Files from './files.js';
import Queue from './queue.js';
import Sync from './sync.js';
import Poller from './poll.js';
import Copies from './copies.js';
import TreeMarks from './ui/tree-marks.js';
import Bars from './ui/bars.js';
import { DeletionsModal } from './ui/deletions.js';
import ConflictCopiesModal from './ui/copies.js';

// Per device, in Obsidian's vault-scoped localStorage (not data.json): a copied vault folder must not bring along
// another device's base
const STATE_KEY = 'rock-sync-state';
const ALL_TYPES_KEY = 'rock-sync-all-types-shown';

class RockSync extends Plugin {
  saveSettings() {
    this.app.saveLocalStorage(SETTINGS_KEY, { ...settings });
  }

  saveState() {
    this.app.saveLocalStorage(STATE_KEY, {
      base: this.base, conflicts: this.conflicts, deleted: this.deleted, hashes: this.hashes, tooLarge: this.tooLarge,
      stubs: this.stubs, review: this.review, firstSyncDue: this.firstSyncDue,
    });
  }

  // Once: settings and state from the data.json era move to localStorage, then data.json is removed
  async migrateDataJson() {
    if (this.app.loadLocalStorage(SETTINGS_KEY) || this.app.loadLocalStorage(STATE_KEY)) return;
    const data = await this.loadData();
    if (!data) return;
    const { endpoint, debug, base, conflicts, deleted } = data;
    this.app.saveLocalStorage(SETTINGS_KEY, { endpoint, debug });
    this.app.saveLocalStorage(STATE_KEY, { base, conflicts, deleted });
    await this.app.vault.adapter.remove(`${this.manifest.dir}/data.json`);
  }

  // No requests until credentials work: queue items wait (the running one runs again), the poller stops. reason:
  // 'credentials' (none: not connected) | 'unauthorized' (the server refused them). One Notice, unless the user just
  // removed the connection; clicking it opens the settings
  pauseSync(reason, { notice = true } = {}) {
    if (this.pausedFor === reason) return;
    debug('sync paused:', reason);
    this.pausedFor = reason;
    this.queue.pause();
    this.poller.stop();
    this.pauseNotice?.hide();
    this.pauseNotice = null;
    if (notice) {
      this.pauseNotice = new Notice(reason === 'unauthorized'
        ? 'Rock Sync: sync paused, the server refused this device: connect it again'
        : 'Rock Sync: not connected, connect this vault in the settings', 0);
      // containerEl: the whole notice (1.8.7+; noticeEl is only its message there)
      (this.pauseNotice.containerEl ?? this.pauseNotice.noticeEl).addEventListener('click', () => this.openSettings());
    }
    this.status.update();
  }

  // Credentials saved: catch up on what waited, then follow the server again
  resumeSync() {
    debug('sync resumed');
    this.pausedFor = null;
    this.pauseNotice?.hide();
    this.pauseNotice = null;
    this.queue.resume();
    this.queue.enqueue('manifest');
    if (this.app.workspace.layoutReady) this.poller.start(); // else startup starts it
    this.status.update();
  }

  // Sync now (settings, command), whatever back-off is running: the saved credentials again if a 401 paused sync; else
  // failed pushes again and a manifest check, every pause between attempts ended (each request's, the poller's).
  // A request in flight can't be cut short (requestUrl). Not connected: the settings, to connect
  syncNow() {
    if (this.pausedFor === 'credentials') return this.openSettings();
    if (this.pausedFor === 'unauthorized') return this.resumeSync();
    for (const path of this.failed) this.queue.enqueue('push', path);
    this.queue.enqueue('manifest');
    retryNow();
    this.poller.wake();
  }

  // Another server or vault (or the first one; endpoint / vault / token already switched): this device's sync state
  // belonged to the old binding. Everything stops, is reset, and the first sync compares both sides without a base —
  // review marks instead of pushes (first-sync.js). Not with a conflict open (the settings refuse it)
  async rebind(switchCredentials) {
    debug('rebind: stopping sync');
    this.queue.pause();
    this.poller.stop();
    await this.queue.idle(); // a request in flight can't be aborted: its answer must not land in the new state
    this.queue.clear();
    switchCredentials();
    this.base = {};
    this.deleted = {};
    this.tooLarge = {};
    this.stubs = {};
    this.hashes = {};
    this.review = {};
    this.failed.clear();
    this.remote = null;
    this.sizes = {};
    this.manifestEtag = null;
    this.firstSyncDue = true;
    await this.saveState();
    this.firstSync.changed();
    debug('rebind: state reset, first sync');
    this.resumeSync();
  }

  // Settings' Remove (credentials already checked there): sync stops, what waits in the queue is dropped (nothing to
  // send it to), the credentials go. The sync state stays until the next connection's rebind
  async disconnect(clearCredentials) {
    debug('disconnect: stopping sync');
    this.queue.pause();
    this.poller.stop();
    await this.queue.idle(); // a request in flight can't be aborted: its answer lands before the credentials go
    this.queue.clear();
    clearCredentials();
    this.pausedFor = null;
    this.pauseSync('credentials', { notice: false });
  }

  openSettings() {
    this.app.setting.open();
    this.app.setting.openTabById(this.manifest.id);
  }

  // Every file type is synced, but Obsidian's file explorer hides types it can't open: a file would arrive and not show
  // up. Turned on once per device (internal vault config, the "Detect all file extensions" setting); turning it off
  // again afterwards is respected
  showAllFileTypes() {
    if (this.app.loadLocalStorage(ALL_TYPES_KEY) || typeof this.app.vault.setConfig !== 'function') return;
    this.app.saveLocalStorage(ALL_TYPES_KEY, true);
    if (this.app.vault.getConfig('showUnsupportedFiles')) return;
    this.app.vault.setConfig('showUnsupportedFiles', true);
    new Notice('Rock Sync: the file explorer now shows files of every type, as all of them are synced '
      + '(Settings → Files and links → Detect all file extensions)');
  }

  async onload() {
    await this.migrateDataJson();
    const stored = this.app.loadLocalStorage(SETTINGS_KEY) ?? {};
    Object.assign(settings, {
      endpoint: stored.endpoint ?? DEFAULT_SETTINGS.endpoint,
      vault: stored.vault ?? DEFAULT_SETTINGS.vault,
      device: stored.device ?? DEFAULT_SETTINGS.device,
      debug: stored.debug ?? DEFAULT_SETTINGS.debug,
    });
    const state = this.app.loadLocalStorage(STATE_KEY) ?? {};
    // path -> hash we last synced on this device
    this.base = state.base ?? {};
    // path -> unresolved conflict: { serverHash, savedAt } of the server version merged against (the resolving push
    // sends If-Match = serverHash), base: hash the merge started from (null: whole file as one block), since. The
    // working copy is in workingCopyFile(path); the note keeps my text, and is merged again if the server changes.
    this.conflicts = state.conflicts ?? {};
    // path -> { deletedAt, reason, serverHash? }: deleted on another device (reason 'remote'), or deleted here while
    // edited on another device (reason 'edited', serverHash: that version, restored locally). Waits for Delete / Keep;
    // not synced meanwhile. Folders: their `.keep` path.
    this.deleted = state.deleted ?? {};
    // path -> [mtime, size, hash] of local files at the last manifest check (localHash)
    this.hashes = state.hashes ?? {};
    // path -> [mtime, size] of a file the server refused as too large (413): never read or sent again while it stays
    // that file (big files don't belong in git; another store for them maybe later)
    this.tooLarge = state.tooLarge ?? {};
    // path -> size of the server version: too large for this device (DEVICE_LIMIT), so an empty file stands in for it
    // (a stub; base = the server version it stands for). Never read, sent, renamed or deleted here; Download replaces it
    this.stubs = state.stubs ?? {};
    // path -> 'local' (not on the server) | 'differs': found by the first sync after a rebind, never sent until reviewed
    // (first-sync.js). Folders: their `.keep` path. firstSyncDue: the next manifest check is that first sync
    this.review = state.review ?? {};
    this.firstSyncDue = state.firstSyncDue ?? false;
    this.remote = null; // path -> hash of the server's last manifest (syncable paths), this session
    this.sizes = {}; // path -> size in bytes, same manifest
    // Paths whose last push failed for good: no answer after all retries, or an unexpected status. Pushed again on the
    // next change or manifest check; cleared by any answer to a push, a local delete or rename
    this.failed = new Set();
    this.applying = new Set(); // paths (and folder prefixes) we're renaming / trashing for the server: not local edits
    this.resolveTimers = new Map(); // path -> { timer, notice } of a pending auto-push
    this.ownWrites = new Set(); // notes we're writing ourselves: not "changed outside the conflict view"
    this.registerView(CONFLICT_VIEW, (leaf) => new ConflictView(leaf, this));
    this.addSettingTab(new RockSyncSettingTab(this.app, this));

    // Every change of the queue may change which paths are unsynced (grey dots, bars)
    this.status = new SyncStatus(this);
    this.queue = new Queue({
      onChange: () => {
        this.treeMarks.schedule();
        this.bars.schedule();
        this.status.update();
      },
      onError: (item, e) => this.status.failed(`${item.key}: ${e.message}`, e),
    });
    this.copies = new Copies(this);
    this.firstSync = new FirstSync(this);
    this.treeMarks = new TreeMarks(this);
    this.bars = new Bars(this);
    this.treeMarks.render();
    this.blockConflictedFileOps();

    this.manifestEtag = null; // manifest version (ETag, echoed as received) this device last saw
    this.poller = new Poller(this);
    this.credentials = new Credentials(this);
    this.credentials.load();
    session.client = clientInfo(this.manifest.version);
    session.onUnauthorized = () => this.pauseSync('unauthorized');
    session.onAnswer = () => this.status.answered();
    this.pausedFor = null; // why sync is paused (pauseSync), null while it runs
    if (!this.credentials.complete()) this.pauseSync('credentials');
    this.registerSyncOps();
    this.registerConflictOps();
    this.registerFileOps();
    this.firstSync.register();

    // Fires after Obsidian writes the file to disk (autosave ~2s after typing stops)
    this.registerEvent(this.app.vault.on('modify', (file) => {
      if (!syncable(file.path) || this.isApplying(file.path)) return; // our own writes for the server (pulls)
      // Its working copy replaces the note on resolve; nothing merges this in
      if (this.conflicts[file.path] && !this.ownWrites.has(file.path)) {
        new Notice(`Rock Sync: ${file.path} changed outside the conflict view; resolving the conflict will replace it`);
      }
      // Editing a file deleted on another device = keeping it
      if (this.deleted[file.path]) return this.decideDeleted(file.path, true);
      if (this.review[file.path]) return; // waits for review; the next manifest check re-evaluates it
      this.queue.enqueue('push', file.path);
    }));
    this.registerEvent(this.app.workspace.on('layout-change', () => this.bars.render()));
    this.addCommand({ id: 'review-deletions', name: 'Review deletions from other devices', callback: () => new DeletionsModal(this).open() });
    this.addCommand({ id: 'review-conflict-copies', name: 'Review conflict copies', callback: () => new ConflictCopiesModal(this).open() });
    this.addCommand({ id: 'review-first-sync', name: 'Review files from first sync', callback: () => new ReviewModal(this).open() });

    // A conflicted note opens as its conflict view, in the same tab. layout-change: after the tab has the note
    // (file-open comes before the tab's state is updated)
    this.registerEvent(this.app.workspace.on('layout-change', () => {
      for (const path of Object.keys(this.conflicts)) this.showConflict(path);
    }));
    this.registerEvent(this.app.workspace.on('file-open', (file) => {
      if (file && this.conflicts[file.path]) this.queue.enqueue('refresh', file.path);
    }));
    // Someone may keep editing on the server meanwhile: conditional GETs for conflicts that are open
    this.registerInterval(window.setInterval(() => {
      for (const path of Object.keys(this.conflicts)) if (this.conflictViewsOf(path).length) this.queue.enqueue('refresh', path);
    }, REMOTE_POLL_INTERVAL));

    this.addCommand({ id: 'sync-now', name: 'Sync now', callback: () => this.syncNow() });
    // Stored server versions may be stale: merge again where needed
    this.app.workspace.onLayoutReady(async () => {
      // After layout ready: during startup Obsidian reports every existing file and folder as created
      this.registerFileEvents();
      this.showAllFileTypes();
      // A conflict copy is one by name, while its original exists: any create / delete / rename may start or end one
      for (const name of ['create', 'delete', 'rename']) {
        this.registerEvent(this.app.vault.on(name, () => {
          this.treeMarks.schedule();
          this.bars.schedule();
        }));
      }
      this.treeMarks.render();
      this.bars.render();
      // Next to the vault name once the workspace exists; Obsidian may rebuild that part on layout changes
      this.statusIcon = new StatusIcon(this);
      this.statusIcon.render();
      this.registerEvent(this.app.workspace.on('layout-change', () => this.statusIcon.render()));
      // Collapsing / expanding the left sidebar isn't a layout change: the workspace's classes say it
      const sidebar = new MutationObserver(() => this.statusIcon.render());
      sidebar.observe(this.app.workspace.containerEl, { attributes: true, attributeFilter: ['class'] });
      this.register(() => sidebar.disconnect());
      await this.migrateLegacyConflicts();
      for (const path of Object.keys(this.conflicts)) {
        this.showConflict(path);
        this.queue.enqueue('refresh', path);
      }
      this.queue.enqueue('manifest');
      // From now on the server tells us when something changes
      if (!this.pausedFor) this.poller.start();
      // Back in the foreground: a mobile app in the background misses polls (and its requests may have failed meanwhile).
      // The main window's document: the app's, not whichever popout has the focus at load
      this.registerDomEvent(window.document, 'visibilitychange', () => {
        if (window.document.visibilityState !== 'visible') return;
        debug('foreground: checking the manifest');
        this.queue.enqueue('manifest');
        this.poller.wake();
      });
    });
  }

  onunload() {
    // Hot reload: the old instance must not keep sending alongside the new one
    for (const path of [...this.resolveTimers.keys()]) this.cancelResolve(path);
    this.queue.stop();
    this.poller.stop();
    this.pauseNotice?.hide();
  }
}

// Method groups mixed into the plugin class — a temporary step of splitting main.js (target: subsystems as classes
// the plugin owns, see CLAUDE.md). A method name defined twice (or shadowing Plugin's) fails the load instead of
// silently overwriting
function mixin(target, groups) {
  for (const [module, group] of Object.entries(groups)) {
    for (const name of Object.getOwnPropertyNames(group.prototype)) {
      if (name === 'constructor') continue;
      if (name in target) throw new Error(`rock-sync: ${module}.${name} is already defined on the plugin`);
      Object.defineProperty(target, name, Object.getOwnPropertyDescriptor(group.prototype, name));
    }
  }
}

mixin(RockSync.prototype, {
  sync: Sync,
  'conflicts/store': ConflictStore,
  files: Files,
});

export default RockSync;
