// The sync status icon, owned by the plugin (`plugin.statusIcon`). Click → the plugin's settings.
// Next to the vault name: Obsidian's own DOM, not a public API — so it's found by selector, checked again on every
// status and layout change, and put back the moment Obsidian re-renders its container (MutationObserver). Where that
// fails (container gone in another Obsidian version) or can't be seen (desktop: left sidebar collapsed), the same icon
// shows in the ribbon (public API) instead: the status is always somewhere.
import { Platform, setTooltip } from 'obsidian';
import SyncStatus from '../status.js';
import { setIconOf } from './icons.js';
import { formatShort } from '../format.js';

const PLACES = [
  // Desktop: bottom of the left sidebar, before the help / settings icons
  {
    container: '.workspace-sidedock-vault-profile .workspace-drawer-vault-actions',
    make: () => createSpan({ cls: 'clickable-icon rock-sync-status' }),
    insert: (container, el) => container.prepend(el),
  },
  // Mobile: the left drawer's header, a round button before the settings one
  {
    container: '.workspace-drawer.mod-left .workspace-drawer-header',
    make: () => createDiv({ cls: 'clickable-icon workspace-drawer-header-icon mod-raised rock-sync-status' }),
    insert: (container, el) => container.insertBefore(el, container.querySelector(':scope > .mod-settings')),
  },
];

export default class StatusIcon {
  constructor(plugin) {
    this.plugin = plugin;
    this.el = null; // the icon next to the vault name
    this.place = null;
    this.observer = null;
    this.ribbon = null; // created the first time it's needed, then only shown / hidden
    this.shown = new Map(); // element -> state key it shows (icon, class, tooltip): no redraw when nothing changed
    this.repairing = false;
    plugin.register(plugin.status.onChange(() => this.render()));
    plugin.register(() => this.remove());
  }

  remove() {
    this.observer?.disconnect();
    this.el?.remove();
    this.el = null;
  }

  // The inline icon is (now) in its container: true
  ensure() {
    if (this.el?.isConnected && this.el.parentElement?.matches(this.place.container)) return true;
    this.remove();
    // The vault name's row is in the main window, whichever window has the focus
    for (const place of PLACES) {
      const container = window.document.querySelector(place.container);
      if (!container) continue;
      this.place = place;
      this.el = place.make();
      this.el.addEventListener('click', () => this.plugin.openSettings());
      place.insert(container, this.el);
      // Obsidian re-rendering the container, or replacing it or any part above it, drops the icon: put it back, after
      // its own change. childList only, no subtree: few events
      this.observer = new MutationObserver(() => {
        if (this.el?.isConnected || this.repairing) return;
        this.repairing = true;
        window.setTimeout(() => {
          this.repairing = false;
          this.render();
        }, 0);
      });
      for (let node = container; node && node !== window.document.body; node = node.parentElement) {
        this.observer.observe(node, { childList: true });
      }
      this.shown.delete(this.el);
      return true;
    }
    return false;
  }

  render() {
    const inline = this.ensure();
    // Desktop: the sidebar's bottom is out of sight while it's collapsed; the ribbon isn't
    const ribbonNeeded = !inline || (!Platform.isMobile && this.plugin.app.workspace.leftSplit?.collapsed);
    if (ribbonNeeded && !this.ribbon) {
      this.ribbon = this.plugin.addRibbonIcon('refresh-cw', 'Rock Sync', () => this.plugin.openSettings());
      this.ribbon.addClass('rock-sync-status');
    }
    this.ribbon?.toggle(ribbonNeeded);
    for (const el of [this.el, this.ribbon]) if (el) this.draw(el);
  }

  draw(el) {
    const { status } = this.plugin;
    const { state } = status;
    const { icon, label } = SyncStatus.describe(state);
    const detail = state === 'error' ? status.errorText
      : status.lastOk ? `last contact ${formatShort(status.lastOk)}` : null;
    const tooltip = `Rock Sync: ${label}${detail ? ` · ${detail}` : ''}`;
    const key = `${state}|${tooltip}`;
    if (this.shown.get(el) === key) return;
    this.shown.set(el, key);
    setIconOf(el, icon);
    for (const s of ['synced', 'syncing', 'offline', 'error']) el.toggleClass(`rock-sync-status-${s}`, s === state);
    if (setTooltip) setTooltip(el, tooltip);
    else el.setAttribute('aria-label', tooltip);
  }
}
