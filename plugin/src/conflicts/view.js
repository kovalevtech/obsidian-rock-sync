// The conflict view: a working copy in its own CodeMirror editor, opened in place of the note's tab
import { ItemView, setIcon } from 'obsidian';
import { EditorView, keymap } from '@codemirror/view';
import { EditorState } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, undo } from '@codemirror/commands';
import { formatSavedAt } from '../format.js';
import {
  conflictBlocks, loadedBlocks, protectMarkers, editSeparator, conflictDecorations,
} from './editor.js';

const SAVE_DELAY = 500; // ms; edits in the conflict view are written to the working copy debounced
const CONFLICT_VIEW = 'rock-sync-conflict';

// The working copy of one conflicted note in its own editor (no Obsidian markdown: plain text, git markers hidden)
class ConflictView extends ItemView {
  constructor(leaf, plugin) {
    super(leaf);
    this.navigation = true; // a tab like a note's: opening another file from it replaces it
    this.plugin = plugin;
    this.path = null;
    this.saveTimer = null;
  }

  getViewType() { return CONFLICT_VIEW; }

  getIcon() { return 'git-merge'; }

  getDisplayText() { return this.path ? `${this.path.split('/').pop().replace(/\.md$/, '')} (conflict)` : 'Conflict'; }

  getState() { return { path: this.path }; }

  async setState(state, result) {
    this.path = state.path;
    await this.load();
    return super.setState(state, result);
  }

  async onOpen() {
    this.contentEl.addClass('rock-sync-conflict-view');
    this.editor = new EditorView({ parent: this.contentEl, state: this.createState('') });
    await this.load();
  }

  async onClose() {
    await this.flush();
    this.editor?.destroy();
  }

  createState(doc) {
    return EditorState.create({
      doc,
      extensions: [
        history(),
        keymap.of([...defaultKeymap, ...historyKeymap]),
        EditorView.lineWrapping,
        conflictBlocks,
        loadedBlocks,
        protectMarkers,
        editSeparator,
        conflictDecorations,
        EditorView.updateListener.of((u) => {
          if (u.docChanged || u.selectionSet) this.renderHeader();
          if (!u.docChanged) return;
          this.scheduleSave();
          if (u.state.field(conflictBlocks).length) this.plugin.cancelResolve(this.path);
          else this.plugin.scheduleResolve(this.path);
        }),
      ],
    });
  }

  // (Re)load the working copy, e.g. after the server version changed: earlier decisions and their undo history go.
  // setState: no update listeners, so nothing is saved back or scheduled by the load itself
  async load() {
    if (!this.editor || !this.path) return;
    const text = await this.plugin.readWorkingCopy(this.path);
    if (text === null) return this.plugin.closeConflictView(this.leaf, this.path); // resolved meanwhile
    window.clearTimeout(this.saveTimer);
    this.saveTimer = null;
    this.editor.setState(this.createState(text));
    this.leaf.updateHeader?.();
    this.renderHeader();
    if (!this.editor.state.field(conflictBlocks).length) this.plugin.scheduleResolve(this.path);
  }

  scheduleSave() {
    window.clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => this.flush(), SAVE_DELAY);
  }

  async flush() {
    if (this.saveTimer === null || !this.editor) return;
    window.clearTimeout(this.saveTimer);
    this.saveTimer = null;
    await this.plugin.writeWorkingCopy(this.path, this.editor.state.doc.toString());
  }

  // "Conflict · i/N ↑ ↓ · server dd.mm.yyyy HH:MM"; i = the block at (or after) the cursor
  renderHeader() {
    if (!this.editor) return;
    const blocks = this.editor.state.field(conflictBlocks);
    const head = this.editor.state.selection.main.head;
    const found = blocks.findIndex((b) => head <= b.end.to);
    const current = found === -1 ? blocks.length : found; // after the last block: ↑ goes to it
    const i = Math.min(current + 1, blocks.length);
    const el = this.titleEl;
    el.empty();
    el.appendText(`Conflict · ${blocks.length ? `${i}/${blocks.length}` : 'none left'} `);
    for (const [icon, step] of [['arrow-up', -1], ['arrow-down', 1]]) {
      const arrow = el.createSpan({ cls: 'rock-sync-header-arrow clickable-icon' });
      setIcon(arrow, icon);
      arrow.addEventListener('click', () => this.goTo(current + step, blocks));
    }
    el.appendText(` · server ${formatSavedAt(this.plugin.conflicts[this.path]?.savedAt)}`);
  }

  goTo(index, blocks) {
    const b = blocks[Math.max(0, Math.min(index, blocks.length - 1))];
    if (!b) return;
    const pos = Math.min(b.start.to + 1, this.editor.state.doc.length);
    this.editor.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'center' }) });
    this.editor.focus();
  }

  undo() {
    if (this.editor) undo(this.editor);
  }
}

export { ConflictView, CONFLICT_VIEW };
