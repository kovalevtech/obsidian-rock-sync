// Conflict copies: the review modal (the bar on a copy: ui/bars.js)
import { Modal, Setting } from 'obsidian';

export default class ConflictCopiesModal extends Modal {
  constructor(plugin) {
    super(plugin.app);
    this.plugin = plugin;
  }

  onOpen() {
    this.titleEl.setText('Conflict copies');
    this.render();
  }

  render() {
    const { contentEl } = this;
    const { copies } = this.plugin;
    contentEl.empty();
    const paths = copies.list().sort();
    if (!paths.length) return contentEl.createEl('p', { text: 'No conflict copies.' });
    const act = async (fn) => {
      await fn();
      this.render();
    };
    for (const path of paths) {
      new Setting(contentEl)
        .setName(path)
        .setDesc(`Conflict copy of ${copies.originOf(path)}`)
        .addButton((b) => b.setButtonText('Open').onClick(() => {
          this.close();
          this.app.workspace.openLinkText(path, '', false);
        }))
        .addButton((b) => b.setButtonText('Replace original').onClick(() => act(() => copies.replaceOriginal(path))))
        .addButton((b) => b.setButtonText('Delete copy').onClick(() => act(() => copies.deleteCopy(path))));
    }
  }
}
