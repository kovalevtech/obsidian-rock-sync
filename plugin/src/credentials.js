// Server credentials (CLAUDE.md "Decisions"): endpoint, vault and this device's name in the settings, the token under
// its own key in the vault-scoped localStorage (never inside the settings object, so a dump of those can't carry it).
// Owned by the plugin: this.credentials. A connection comes only from a one-time code (pair): the settings tab holds
// what it gave as a draft and checks it here; the running sync keeps the saved one until Save.
import { settings } from './settings.js';
import { debug } from './log.js';
import { session, request, manifestUrl, pairUrl, tokenUrl, readManifest } from './api.js';
import { compareManifests } from './decisions.js';

const TOKEN_KEY = 'rock-sync-token';

export default class Credentials {
  constructor(plugin) {
    this.plugin = plugin;
    this.app = plugin.app;
  }

  load() {
    session.token = this.app.loadLocalStorage(TOKEN_KEY) ?? '';
  }

  // What the running sync uses
  saved() {
    return { endpoint: settings.endpoint, vault: settings.vault, token: session.token, device: settings.device };
  }

  complete({ endpoint, vault, token } = this.saved()) {
    return Boolean(endpoint && vault && token);
  }

  // Same server and vault as the running sync: Save only stores the token. Otherwise (or no vault yet) the sync state
  // belongs to another vault: a rebind
  sameBinding(draft) {
    return Boolean(settings.vault) && draft.endpoint === settings.endpoint && draft.vault === settings.vault;
  }

  // POST /pair: { status: 'paired', draft: { endpoint, vault, token, device } } | { status: 'refused' } (wrong, used or
  // expired) | { status: 'name', error } | { status: 'limited' } | { status: 'unreachable' }. One attempt: the user is
  // waiting, and a wrong try counts. The token is shown only this once: Save keeps it, anything else revokes it
  async pair({ endpoint, code, name }) {
    try {
      const res = await request({
        url: pairUrl(endpoint),
        method: 'POST',
        contentType: 'application/json',
        body: JSON.stringify({ code, name }),
        credentials: { endpoint, vault: '', token: '' },
        attempts: 1,
        throw: false,
      });
      if (res.status === 401) return { status: 'refused' };
      if (res.status === 422) return { status: 'name', error: res.json.error };
      if (res.status === 429) return { status: 'limited' };
      if (res.status !== 200) throw new Error(`status ${res.status}`);
      const { token, vault, name: device } = res.json;
      return { status: 'paired', draft: { endpoint, vault, token, device } };
    } catch (e) {
      debug('pairing: server unreachable', String(e));
      return { status: 'unreachable' };
    }
  }

  // DELETE /token: a token no vault here uses any more revokes itself. One attempt, its answer doesn't matter: offline,
  // the admin panel revokes it; a token with several vaults (from before codes) is kept by the server (409).
  // With the token's vault (the saved one, or an unsaved draft's): it goes out as X-Rock-Sync-Vault too, so a proxy
  // letting only that vault through lets the revoke through as well (the server checks it against the token's)
  async revoke({ endpoint, vault, token }) {
    if (!endpoint || !token) return;
    try {
      const res = await request({ url: tokenUrl(endpoint), method: 'DELETE', credentials: { endpoint, vault, token }, attempts: 1, throw: false });
      debug('token revoked:', res.status);
    } catch (e) {
      debug('token not revoked: server unreachable', String(e));
    }
  }

  // GET /manifest with the draft, then the local side: { status: 'ok', summary: compareManifests(…) } |
  // { status: 'unauthorized' } | { status: 'unreachable' }. One attempt, no retries: the user is waiting
  async check(draft, { signal, onProgress } = {}) {
    let remote;
    try {
      const res = await request({ url: manifestUrl(draft.endpoint), credentials: draft, attempts: 1, throw: false, signal });
      if (res.status === 401) return { status: 'unauthorized' };
      if (res.status !== 200) throw new Error(`status ${res.status}`);
      ({ remote } = readManifest(res.json));
    } catch (e) {
      debug('credentials check: server unreachable', String(e));
      return { status: 'unreachable' };
    }
    const { local } = await this.plugin.localManifest({ signal, onProgress });
    return { status: 'ok', summary: compareManifests(local, remote) };
  }

  // Open conflicts belong to the old binding's server versions: a rebind or a removal waits until they're resolved
  canRebind() {
    return Object.keys(this.plugin.conflicts).length === 0;
  }

  // A paired draft. Same binding: the token is stored, sync resumes with it. Else a rebind: the sync state is reset and
  // the first sync runs. The old token, replaced, revokes itself (a Reconnect's is dead already)
  async save(draft) {
    const old = this.saved();
    if (this.sameBinding(draft)) {
      this.store(draft);
      this.plugin.resumeSync();
    } else {
      if (!this.canRebind()) throw new Error('rock-sync: resolve the open conflicts before switching the server or vault');
      await this.plugin.rebind(() => this.store(draft));
    }
    if (old.token !== draft.token) await this.revoke(old);
  }

  // Settings' Remove: sync stops, the token revokes itself, nothing of the connection stays here but the server URL (the
  // next code's default). The sync state stays: the next connection is a rebind, which resets it
  async remove() {
    if (!this.canRebind()) throw new Error('rock-sync: resolve the open conflicts before removing the connection');
    const old = this.saved();
    await this.plugin.disconnect(() => this.store({ endpoint: old.endpoint, vault: '', token: '', device: '' }));
    await this.revoke(old);
  }

  store({ endpoint, vault, token, device }) {
    Object.assign(settings, { endpoint, vault, device });
    this.plugin.saveSettings();
    this.app.saveLocalStorage(TOKEN_KEY, token || null);
    session.token = token;
  }
}
