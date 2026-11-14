// The sync status, owned by the plugin (`plugin.status`): one source for everything showing it (the icon next to the
// vault name, the settings' top block, later a note header icon). Derived on demand from the plugin's state plus the
// last successful contact and the last error; listeners hear about every change.
//   error    sync paused (not connected / credentials refused), or an unexpected failure since the last answer from the server
//   offline  the poller is backing off (no answer)
//   syncing  queue items waiting or running
//   synced   none of that
import { NoAnswer } from './api.js';

const STATES = {
  synced: { icon: ['cloud-check', 'cloud'], label: 'Synced' },
  syncing: { icon: ['refresh-cw'], label: 'Syncing' },
  offline: { icon: ['cloud-off', 'wifi-off'], label: 'Offline' },
  error: { icon: ['cloud-alert', 'alert-circle'], label: 'Sync error' },
};

export default class SyncStatus {
  constructor(plugin) {
    this.plugin = plugin;
    this.lastOk = null; // Date of the last answer from the server (any request of the running sync, polls included)
    this.lastError = null; // { text, at: Date }
    this.listeners = new Set();
    // The countdown to the poller's next try: listeners re-render every second while there is one
    plugin.registerInterval(window.setInterval(() => {
      if (plugin.poller?.problem?.retryAt) this.update();
    }, 1000));
  }

  static describe(state) {
    return STATES[state];
  }

  get state() {
    const { plugin } = this;
    if (plugin.pausedFor) return 'error';
    if (this.lastError && (!this.lastOk || this.lastError.at > this.lastOk)) return 'error';
    if (plugin.poller.failures > 0) return 'offline';
    if (plugin.queue.size() > 0) return 'syncing';
    return 'synced';
  }

  // Why it's an error, for the settings / tooltip
  get errorText() {
    const { pausedFor } = this.plugin;
    if (pausedFor === 'credentials') return 'Not connected: connect this vault below';
    if (pausedFor === 'unauthorized') return "Sync paused: the server refused this device's token. Connect it again (Reconnect in the admin panel)";
    return this.lastError?.text ?? null;
  }

  // Why the poller is backing off (the server may have answered: 429, 5xx…) and when it tries again
  get offlineText() {
    const { problem } = this.plugin.poller;
    if (!problem) return "The server doesn't answer";
    if (!problem.retryAt) return `${problem.text} · trying again`;
    const seconds = Math.max(0, Math.ceil((problem.retryAt - Date.now()) / 1000));
    return `${problem.text} · next try in ${seconds} s`;
  }

  // What's wrong, for the settings / tooltip: null while synced or syncing
  get problemText() {
    const { state } = this;
    return state === 'error' ? this.errorText : state === 'offline' ? this.offlineText : null;
  }

  answered() {
    this.lastOk = new Date();
    this.update();
  }

  // A queue item failed (not offline: no answer at all is the poller's to show), or an unexpected status
  failed(text, error) {
    if (error instanceof NoAnswer) return;
    this.lastError = { text, at: new Date() };
    this.update();
  }

  onChange(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  update() {
    for (const listener of this.listeners) {
      try {
        listener(this);
      } catch (e) {
        console.error('rock-sync: status listener failed', e); // one broken view mustn't stop the others
      }
    }
  }
}
