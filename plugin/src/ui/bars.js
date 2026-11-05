// Bars at the top of a file's view, owned by the plugin (`plugin.bars`): why the file has its mark in the tree, and the
// choices. Deleted on another device (Delete / Keep), a conflict copy (Replace original / Delete copy), waiting for
// review after the first sync (Push; Take server / Keep mine / Merge or Keep both), a stub: too large for this device
// (Download), not synced: too large, or the last upload failed (Retry). None for a conflict (its own view) or a push just queued (too brief)
import { FileView, TFile, debounce, setIcon } from 'obsidian';
import { formatShort, formatSize } from '../format.js';

export default class Bars {
  constructor(plugin) {
    this.plugin = plugin;
    this.schedule = debounce(() => this.render(), 300);
  }

  // Notes: above the title, inside the scrolling note (editing and reading mode), not on top of the view — on phones
  // the header floats over the view's top. Other views (image, PDF, audio, video, canvas) have no such sizer: at the
  // top of their content
  render() {
    this.plugin.app.workspace.iterateAllLeaves((leaf) => {
      const { view } = leaf;
      if (!(view instanceof FileView)) return;
      view.containerEl.querySelectorAll('.rock-sync-bar').forEach((el) => el.remove());
      const bar = view.file && this.barOf(view.file.path);
      if (!bar) return;
      const hosts = view.getViewType() === 'markdown'
        ? [...view.containerEl.querySelectorAll('.cm-sizer, .markdown-preview-sizer')]
        : [view.contentEl];
      for (const host of hosts) host.prepend(this.build(bar, host === view.contentEl));
    });
  }

  barOf(path) {
    const { plugin } = this;
    const mark = plugin.deleted[path];
    if (mark) {
      return {
        icon: 'trash-2',
        text: `${mark.reason === 'edited' ? 'Edited on another device after you deleted it' : 'Deleted on another device'} · ${formatShort(mark.deletedAt)}`,
        actions: { Delete: () => plugin.decideDeleted(path, false), Keep: () => plugin.decideDeleted(path, true) },
      };
    }
    const origin = plugin.copies.originOf(path);
    if (origin) {
      return {
        icon: 'copy',
        text: `Conflict copy of ${origin}`,
        actions: { 'Replace original': () => plugin.copies.replaceOriginal(path), 'Delete copy': () => plugin.copies.deleteCopy(path) },
      };
    }
    const review = plugin.review[path];
    if (review) {
      return {
        icon: review === 'local' ? 'cloud-upload' : 'git-compare',
        text: review === 'local' ? 'Not on the server yet' : 'Differs from the server',
        actions: plugin.firstSync.actionsOf(path),
      };
    }
    const stub = plugin.stubs[path];
    if (stub !== undefined) {
      return {
        icon: 'cloud-download',
        text: `Not on this device: too large (${formatSize(stub)})`,
        actions: { Download: () => plugin.queue.enqueue('download', path) },
      };
    }
    if (plugin.tooLarge[path]) {
      return { icon: 'file-x', text: `Not synced: too large for the server (${formatSize(plugin.tooLarge[path][1])})`, actions: {} };
    }
    const file = plugin.app.vault.getAbstractFileByPath(path);
    if (file instanceof TFile && plugin.tooLargeHere(file)) {
      return { icon: 'file-x', text: `Not synced: too large to send from this device (${formatSize(file.stat.size)})`, actions: {} };
    }
    if (plugin.failed.has(path)) {
      return {
        icon: 'cloud-off',
        text: 'Not synced: the last upload failed (no connection to the server?)',
        actions: { Retry: () => plugin.queue.enqueue('push', path) },
      };
    }
    return null;
  }

  build({ icon, text, actions }, inView) {
    const el = createDiv({ cls: inView ? 'rock-sync-bar rock-sync-bar-in-view' : 'rock-sync-bar' });
    const label = el.createDiv({ cls: 'rock-sync-bar-label' });
    setIcon(label.createSpan({ cls: 'rock-sync-bar-icon' }), icon);
    label.createSpan({ text });
    // One group: on a narrow screen the buttons wrap to their own row together, under the label's left edge
    const buttons = el.createDiv({ cls: 'rock-sync-bar-actions' });
    for (const [label, act] of Object.entries(actions)) buttons.createEl('button', { text: label }).addEventListener('click', act);
    return el;
  }
}
