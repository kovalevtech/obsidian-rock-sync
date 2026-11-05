// Deletions from other devices: the review modal (the bar on a marked file: ui/bars.js)
import { Modal, Setting } from 'obsidian';
import { isKeep, folderOfKeep } from '../paths.js';
import { formatShort } from '../format.js';

// Everything deleted on another device (or edited there after I deleted it), waiting for Delete / Keep
class DeletionsModal extends Modal {
  constructor(plugin) {
    super(plugin.app);
    this.plugin = plugin;
  }

  onOpen() {
    this.titleEl.setText('Deletions from other devices');
    this.render();
  }

  render() {
    const { contentEl } = this;
    contentEl.empty();
    const paths = Object.keys(this.plugin.deleted).sort();
    if (!paths.length) return contentEl.createEl('p', { text: 'Nothing waiting.' });
    const decide = async (list, keep) => {
      for (const path of list) await this.plugin.decideDeleted(path, keep);
      this.render();
    };
    for (const path of paths) {
      const mark = this.plugin.deleted[path];
      new Setting(contentEl)
        .setName(isKeep(path) ? `${folderOfKeep(path)}/` : path)
        .setDesc(`${mark.reason === 'edited' ? 'Edited on another device after you deleted it' : 'Deleted on another device'} · ${formatShort(mark.deletedAt)}`)
        .addButton((b) => b.setButtonText('Delete').onClick(() => decide([path], false)))
        .addButton((b) => b.setButtonText('Keep').onClick(() => decide([path], true)));
    }
    new Setting(contentEl)
      .addButton((b) => b.setButtonText('Delete all').setWarning().onClick(() => decide(paths, false)))
      .addButton((b) => b.setButtonText('Keep all').onClick(() => decide(paths, true)));
  }
}

export { DeletionsModal };
