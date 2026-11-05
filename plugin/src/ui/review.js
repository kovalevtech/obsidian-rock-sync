// Files from the first sync after a rebind, waiting for review: the modal (the bar on a marked file: ui/bars.js).
// Actions are queue ops (first-sync.js); the list re-renders as they run
import { Modal, Setting } from 'obsidian';
import { isKeep } from '../paths.js';

export default class ReviewModal extends Modal {
  constructor(plugin) {
    super(plugin.app);
    this.plugin = plugin;
  }

  onOpen() {
    this.titleEl.setText('Review files from first sync');
    this.plugin.firstSync.modal = this;
    this.render();
  }

  onClose() {
    if (this.plugin.firstSync.modal === this) this.plugin.firstSync.modal = null;
  }

  render() {
    const { contentEl } = this;
    const { firstSync, queue } = this.plugin;
    contentEl.empty();
    const { local, differs } = firstSync.list();
    if (!local.length && !differs.length) return contentEl.createEl('p', { text: 'Nothing waiting.' });
    const all = (paths, op) => () => paths.forEach((path) => queue.enqueue(op, path));

    const group = (title, desc, paths, bulk) => {
      if (!paths.length) return;
      const heading = new Setting(contentEl).setHeading().setName(`${title} (${paths.length})`).setDesc(desc);
      for (const [label, act] of Object.entries(bulk)) heading.addButton((b) => b.setButtonText(label).onClick(act));
      for (const path of paths) {
        const row = new Setting(contentEl).setName(firstSync.label(path));
        if (!isKeep(path)) {
          row.addButton((b) => b.setButtonText('Open').onClick(() => {
            this.close();
            this.app.workspace.openLinkText(path, '', false);
          }));
        }
        for (const [label, act] of Object.entries(firstSync.actionsOf(path))) row.addButton((b) => b.setButtonText(label).onClick(act));
      }
    };
    group('Only here', 'Not on the server yet', local, { 'Push all': all(local, 'review-push') });
    group('Different', 'Here and on the server, with different content', differs, {
      'Take server all': all(differs, 'review-take'),
      'Keep mine all': all(differs, 'review-keep'),
    });
  }
}
