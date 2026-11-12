import { Platform, PluginSettingTab, Setting } from 'obsidian';
import { formatSavedAt } from './format.js';
import { codeOf, isCode, linkOf, insecure, deviceNameOf, defaultDeviceName } from './pairing.js';
import { setIconOf } from './ui/icons.js';

// device: the name this device's token has on the server (the author of its commits), as /pair answered
const DEFAULT_SETTINGS = { endpoint: 'http://localhost:9292', vault: '', device: '', debug: false };

// localStorage key (vault-scoped) of the stored settings
const SETTINGS_KEY = 'rock-sync-settings';

// The plugin's settings, shared by every module: filled in place on load / change (Object.assign), never replaced.
// The token is not here: its own localStorage key (Credentials)
const settings = { ...DEFAULT_SETTINGS };

const BUSY = ['pairing', 'checking', 'hashing', 'saving', 'switching', 'removing'];
const FAILED = ['refused', 'name', 'limited', 'unreachable', 'unauthorized', 'failed', 'conflicts'];

const MESSAGES = {
  refused: 'The server refused this code: wrong, expired or already used',
  limited: 'Too many tries: wait a minute',
  unreachable: 'Server unreachable',
  unauthorized: 'The server refused the new token',
  failed: 'Check failed (see the developer console)',
  pairing: 'Connecting…',
  checking: 'Checking…',
  switching: 'Switching: waiting for the running request…',
  removing: 'Removing: waiting for the running request…',
};

const ENDPOINT_DESC = 'Address of the sync server, or the connection link (server and code in one)';
const INSECURE = 'Not encrypted: the token and your notes travel in the clear. Use HTTPS, or a VPN such as Tailscale';

// A setting's description, the warning under it when the server URL sends everything in the clear
const describeEndpoint = (setting, desc, endpoint) => {
  setting.setDesc(desc);
  if (insecure(endpoint)) setting.descEl.createDiv({ cls: 'rock-sync-insecure', text: INSECURE });
};

const hostOf = (endpoint) => {
  try {
    return new URL(endpoint).host;
  } catch {
    return endpoint;
  }
};

class RockSyncSettingTab extends PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
    this.checks = 0; // a newer check (or Cancel, or closing the tab) makes older results stale
  }

  // The connection is shown, or (none yet, or Edit) edited: server URL + a one-time code + this device's name →
  // Connect (POST /pair) → a draft { endpoint, vault, token, device } for the code's vault, checked against the local
  // files → Save. The running sync keeps the saved connection until then; a draft not saved (Cancel, the tab closed)
  // revokes its token. A code for the connected vault on the same server (Reconnect) is saved right away: nothing to
  // review, only the token changes
  display() {
    const { containerEl } = this;
    containerEl.empty();
    this.stopCheck();

    // Status on top, live while the tab is open. Re-rendered every second while counting down to the next try: its
    // parts are made once (a button replaced under the pointer loses the click), only their content changes
    this.statusEl = containerEl.createDiv({ cls: 'rock-sync-status-card' });
    this.statusIconEl = this.statusEl.createDiv();
    this.statusBodyEl = this.statusEl.createDiv({ cls: 'rock-sync-status-card-body' });
    this.syncButton = this.statusEl.createEl('button', { text: 'Sync now' });
    this.syncButton.addEventListener('click', () => this.plugin.syncNow());
    this.unsubscribe?.();
    this.unsubscribe = this.plugin.status.onChange(() => this.renderStatus());
    this.renderStatus();

    new Setting(containerEl).setName('Connection').setHeading();
    this.connectionEl = containerEl.createDiv();
    this.showConnection(this.plugin.credentials.complete() ? 'view' : 'edit');

    new Setting(containerEl)
      .setName('Debug logging')
      .setDesc('Verbose sync log in the developer console (Cmd+Opt+I)')
      .addToggle((toggle) => toggle
        .setValue(settings.debug)
        .onChange(async (value) => {
          settings.debug = value;
          this.plugin.saveSettings();
        }));
  }

  hide() {
    this.stopCheck();
    this.dropDraft();
    this.unsubscribe?.();
    this.unsubscribe = null;
    super.hide();
  }

  stopCheck() {
    this.checks++;
    this.checkController?.abort();
  }

  // A paired token that wasn't saved: shown once, nobody has it any more
  dropDraft() {
    if (this.draft) this.plugin.credentials.revoke(this.draft);
    this.draft = null;
  }

  // mode: 'view' (the saved connection; Edit, Remove) | 'edit' (a code to connect with). result: a message kept across
  // the switch (Saved, Switched)
  showConnection(mode, result = null) {
    this.mode = mode;
    this.result = result;
    this.draft = null;
    this.removing = false;
    this.connectionEl.empty();
    if (mode === 'view') this.buildView();
    else this.buildEdit();
    this.render();
  }

  buildView() {
    const el = this.connectionEl;
    const row = (name, value) => {
      const setting = new Setting(el).setName(name);
      setting.controlEl.createSpan({ cls: 'rock-sync-connection-value', text: value });
      return setting;
    };
    describeEndpoint(row('Server', settings.endpoint), '', settings.endpoint);
    row('Vault', settings.vault);
    row('Device', settings.device || '—');
    this.actions = new Setting(el)
      .addButton((b) => { this.editButton = b.setButtonText('Edit').onClick(() => this.showConnection('edit')); })
      .addButton((b) => {
        this.removeButton = b.setButtonText('Remove').setWarning().onClick(() => this.remove());
      })
      .addButton((b) => {
        this.keepButton = b.setButtonText('Cancel').onClick(() => {
          this.removing = false;
          this.render();
        });
      });
  }

  buildEdit() {
    const el = this.connectionEl;
    const saved = this.plugin.credentials.saved();
    this.form = {
      endpoint: saved.endpoint || DEFAULT_SETTINGS.endpoint,
      code: '',
      name: saved.device || defaultDeviceName(Platform),
    };
    this.inputs = {};
    const field = (key, name, desc, configure = () => {}) => new Setting(el)
      .setName(name)
      .setDesc(desc)
      .addText((text) => {
        this.inputs[key] = text;
        configure(text);
        text.setValue(this.form[key]).onChange((value) => {
          this.form[key] = value;
          // The connection link, pasted into Server URL or the code: both fields from it
          const link = key !== 'name' && linkOf(value);
          if (link) {
            Object.assign(this.form, link);
            this.inputs.endpoint.setValue(link.endpoint);
            this.inputs.code.setValue(link.code);
          }
          this.result = null;
          this.render();
        });
      });
    this.endpointSetting = field('endpoint', 'Server URL', ENDPOINT_DESC, (text) => text.setPlaceholder(DEFAULT_SETTINGS.endpoint));
    field('code', 'Connection code', "From the server's admin panel (Vaults, Connect device), or its connection link. Connects that vault, works once", (text) => {
      text.inputEl.inputMode = 'numeric';
      text.setPlaceholder('482 913');
    });
    field('name', 'Device name', 'The author of what this device changes, on the server');
    this.actions = new Setting(el)
      .addButton((b) => { this.cancelButton = b.setButtonText('Cancel').onClick(() => this.cancel()); })
      .addButton((b) => { this.connectButton = b.setButtonText('Connect').setCta().onClick(() => this.connect()); })
      .addButton((b) => { this.saveButton = b.setButtonText('Save').setCta().onClick(() => this.save()); });
  }

  canConnect() {
    const { endpoint, code, name } = this.form;
    return !this.draft && !BUSY.includes(this.result?.status)
      && Boolean(endpoint.trim()) && isCode(codeOf(code)) && Boolean(deviceNameOf(name));
  }

  // Only by this button: a code works once, and wrong tries count. One attempt
  async connect() {
    if (!this.canConnect()) return;
    this.stopCheck();
    const id = this.checks;
    const endpoint = this.form.endpoint.trim().replace(/\/+$/, '');
    const name = deviceNameOf(this.form.name);
    this.inputs.name.setValue(name);
    this.form.name = name;
    this.result = { status: 'pairing' };
    this.render();

    const { credentials } = this.plugin;
    const paired = await credentials.pair({ endpoint, code: codeOf(this.form.code), name });
    if (paired.status !== 'paired') {
      if (id === this.checks) {
        this.result = { status: paired.status, error: paired.error };
        this.render();
      }
      return;
    }
    if (id !== this.checks) return credentials.revoke(paired.draft); // canceled or closed meanwhile
    this.form.code = '';
    this.inputs.code.setValue('');
    this.draft = paired.draft;
    if (credentials.sameBinding(this.draft)) return this.save();
    this.runCheck();
  }

  // The draft's vault: GET /manifest + the local side → the summary Save is offered on
  async runCheck() {
    this.stopCheck();
    const id = this.checks;
    const controller = new AbortController();
    this.checkController = controller;
    this.result = { status: 'checking' };
    this.render();

    let result;
    try {
      result = await this.plugin.credentials.check(this.draft, {
        signal: controller.signal,
        onProgress: (done, total) => {
          if (id !== this.checks) return;
          this.result = { status: 'hashing', done, total };
          this.render();
        },
      });
    } catch (e) {
      if (controller.signal.aborted) return; // canceled or closed meanwhile
      console.error('rock-sync: credentials check failed', e);
      result = { status: 'failed' };
    }
    if (id !== this.checks) return;
    this.result = result;
    this.render();
  }

  canSave() {
    const { credentials } = this.plugin;
    return Boolean(this.draft) && (credentials.sameBinding(this.draft)
      || (this.result?.status === 'ok' && credentials.canRebind()));
  }

  async save() {
    if (!this.canSave()) return;
    const { credentials } = this.plugin;
    const draft = this.draft;
    const rebind = !credentials.sameBinding(draft);
    this.stopCheck();
    this.draft = null; // saved from here on: never revoked as a draft
    this.result = { status: rebind ? 'switching' : 'saving' };
    this.render();
    await credentials.save(draft);
    this.showConnection('view', { status: rebind ? 'switched' : 'saved' });
  }

  // Back to the saved connection (if any); a paired draft is revoked
  cancel() {
    this.stopCheck();
    this.dropDraft();
    if (this.plugin.credentials.complete()) return this.showConnection('view');
    this.result = null;
    this.render();
  }

  // Asks first (the same button row): sync stops here, the token revokes itself, the files stay
  async remove() {
    const { credentials } = this.plugin;
    if (!this.removing) {
      this.removing = true;
      this.result = credentials.canRebind() ? null : { status: 'conflicts' };
      return this.render();
    }
    if (!credentials.canRebind()) return;
    this.result = { status: 'removing' };
    this.render();
    await credentials.remove();
    this.showConnection('edit', { status: 'removed' });
  }

  render() {
    this.renderStatus();
    const status = this.result?.status;
    const busy = BUSY.includes(status);
    this.actions.setDesc(this.resultText());
    this.actions.descEl.toggleClass('rock-sync-check-error', FAILED.includes(status));
    if (this.mode === 'view') {
      this.editButton.buttonEl.toggle(!this.removing);
      this.keepButton.buttonEl.toggle(Boolean(this.removing));
      this.removeButton.setDisabled(busy || status === 'conflicts');
      this.keepButton.setDisabled(busy);
      return;
    }
    const connected = this.plugin.credentials.complete();
    describeEndpoint(this.endpointSetting, ENDPOINT_DESC, this.form.endpoint);
    for (const text of Object.values(this.inputs)) text.setDisabled(Boolean(this.draft) || busy);
    this.cancelButton.buttonEl.toggle(connected || Boolean(this.draft));
    this.cancelButton.setDisabled(status === 'switching');
    this.connectButton.buttonEl.toggle(!this.draft);
    this.connectButton.setDisabled(!this.canConnect());
    this.saveButton.buttonEl.toggle(Boolean(this.draft));
    this.saveButton.setDisabled(!this.canSave());
  }

  resultText() {
    const r = this.result;
    if (this.removing && r?.status !== 'removing') {
      return r?.status === 'conflicts' ? 'Resolve the open conflicts first'
        : "Remove this connection? Sync stops here and this device's token is revoked on the server. The files stay";
    }
    if (!r) return this.mode === 'edit' && !this.plugin.credentials.complete() ? 'Not connected' : '';
    switch (r.status) {
      case 'name': return r.error ?? 'The server refused this device name';
      case 'hashing': return `Connected. Reading local files ${r.done} / ${r.total}…`;
      case 'saving': return 'Saving…';
      case 'saved': return 'Saved: the device has its new token';
      case 'switched': return 'Switched. First sync running: files only on the server are downloaded, the rest waits for review';
      case 'removed': return 'Removed: this vault no longer syncs';
      case 'ok': return this.summaryText(r.summary);
      default: return MESSAGES[r.status] ?? '';
    }
  }

  summaryText(s) {
    const { vault, endpoint, device } = this.draft;
    const summary = `${vault} on ${hostOf(endpoint)}, as ${device}. Identical ${s.identical.length} · `
      + `only here ${s.localOnly.length} · only on the server ${s.remoteOnly.length} · different ${s.differs.length}`;
    if (!this.plugin.credentials.canRebind()) return `${summary}. Resolve the open conflicts before switching the server or vault`;
    // A rebind resets this device's sync state: the first sync pulls what's only on the server, the rest is reviewed
    return `${summary}. Save switches this vault to it: files only on the server are downloaded, `
      + 'files only here or different wait for your review';
  }

  renderStatus() {
    const { statusEl: el, statusIconEl: iconEl, statusBodyEl: body } = this;
    if (!el) return;
    const { status, queue, pausedFor } = this.plugin;
    const { state } = status;
    const { icon, label } = status.constructor.describe(state);
    el.className = `rock-sync-status-card rock-sync-status-card-${state}`;

    iconEl.className = `rock-sync-status-card-icon rock-sync-status rock-sync-status-${state}`;
    setIconOf(iconEl, icon);
    body.empty();
    body.createDiv({ cls: 'rock-sync-status-card-title', text: label });
    const meta = [
      settings.vault ? `${settings.vault} on ${hostOf(settings.endpoint)}` : 'Not connected',
      `last sync ${status.lastOk ? formatSavedAt(status.lastOk) : 'never'}`,
    ];
    if (queue.size()) meta.push(`${queue.size()} waiting`);
    body.createDiv({ cls: 'rock-sync-status-card-meta', text: meta.join(' · ') });

    const error = status.problemText;
    if (error) body.createDiv({ cls: 'rock-sync-status-card-problem', text: error });
    else if (status.lastError) {
      body.createDiv({
        cls: 'rock-sync-status-card-meta',
        text: `Last error: ${status.lastError.text} · ${formatSavedAt(status.lastError.at)}`,
      });
    }

    // Not connected: nothing to sync with, a code below fixes it
    this.syncButton.toggle(pausedFor !== 'credentials');
  }
}

export { DEFAULT_SETTINGS, SETTINGS_KEY, settings, RockSyncSettingTab };
