// File tree markers, owned by the plugin (`plugin.treeMarks`): a stylesheet rebuilt from the sync state — plain CSS,
// survives explorer re-renders. Constructable, not a <style>: the community directory refuses plugins creating those.
// The selectors name paths, so they can't be in styles.css
import { debounce } from 'obsidian';
import { isKeep, folderOfKeep, syncable } from '../paths.js';
import { DEVICE_LIMIT } from '../api.js';

// Dot kinds by priority: one dot per path, the first kind that applies. Colors: --rock-sync-dot-* in styles.css
const DOTS = ['conflict', 'copy', 'review', 'pending', 'stub'];
// Drawn as a ring (border, same outer size) instead of a dot: [color variable]
const RINGS = { review: '--rock-sync-dot-review', stub: '--rock-sync-dot-pending' };

export default class TreeMarks {
  constructor(plugin) {
    this.plugin = plugin;
    // The main window's document, not activeDocument: the file explorer lives there, and a constructed sheet can't be
    // adopted by another window's document (the plugin may load while Settings, a popout, has the focus)
    const doc = window.document;
    // Older WebViews (iOS before 16.4) have none: no marks there, the sync doesn't depend on them
    this.sheet = 'adoptedStyleSheets' in doc ? new CSSStyleSheet() : null;
    if (this.sheet) {
      doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, this.sheet];
      plugin.register(() => {
        doc.adoptedStyleSheets = doc.adoptedStyleSheets.filter((sheet) => sheet !== this.sheet);
      });
    }
    // For changes that come in bursts (vault events, queue items): at most every 300 ms, not postponed while they
    // keep coming (a long sync still shows its progress)
    this.schedule = debounce(() => this.render(), 300);
  }

  // A dot after the name of the file and every parent folder (collapsed folders show it too): red = open conflict,
  // yellow = conflict copy, yellow ring = waiting for review (first sync), grey = not synced (a push / delete / move
  // queued or running, the last push failed for good, or too large to send), grey ring = a stub (too large for this
  // device, not downloaded; its name muted). Files and folders deleted on another device are struck through
  render() {
    const { plugin } = this;
    const quote = (path) => `"${path.replace(/["\\]/g, '\\$&')}"`;
    const dots = new Map(); // selector -> kind
    const mark = (syncPath, kind) => {
      const path = isKeep(syncPath) ? folderOfKeep(syncPath) : syncPath;
      const parts = path.split('/');
      const selectors = [`.nav-${isKeep(syncPath) ? 'folder' : 'file'}-title[data-path=${quote(path)}]`];
      for (let i = 1; i < parts.length; i++) selectors.push(`.nav-folder-title[data-path=${quote(parts.slice(0, i).join('/'))}]`);
      for (const sel of selectors) if (!dots.has(sel) || DOTS.indexOf(kind) < DOTS.indexOf(dots.get(sel))) dots.set(sel, kind);
    };
    for (const path of Object.keys(plugin.conflicts)) mark(path, 'conflict');
    for (const path of plugin.copies.list()) mark(path, 'copy');
    for (const path of Object.keys(plugin.review)) mark(path, 'review');
    // Too large to read here (mobile): only stat is looked at
    const tooLargeHere = DEVICE_LIMIT < Infinity
      ? plugin.app.vault.getFiles().filter((f) => syncable(f.path) && plugin.tooLargeHere(f)).map((f) => f.path) : [];
    for (const path of new Set([...plugin.queue.pending(), ...plugin.failed, ...Object.keys(plugin.tooLarge), ...tooLargeHere])) {
      mark(path, 'pending');
    }
    for (const path of Object.keys(plugin.stubs)) mark(path, 'stub');

    const struck = Object.keys(plugin.deleted).map((path) => (isKeep(path)
      ? `.nav-folder-title[data-path=${quote(folderOfKeep(path))}] .nav-folder-title-content`
      : `.nav-file-title[data-path=${quote(path)}] .nav-file-title-content`));
    const muted = Object.keys(plugin.stubs).map((path) => `.nav-file-title[data-path=${quote(path)}] .nav-file-title-content`);
    const after = (sels) => sels.map((sel) => `${sel}::after`).join(',\n');
    // A dot right after the name: doesn't fight the rounded item background or the nesting guide lines. The file type
    // tag (non-markdown files; pushed right by its auto margin) moves behind the dot
    this.sheet?.replaceSync([
      dots.size ? `${after([...dots.keys()])} {
          content: ''; flex-shrink: 0; align-self: center; margin-inline-start: var(--size-4-2);
          width: var(--rock-sync-dot-size); height: var(--rock-sync-dot-size); border-radius: 50%;
        }
        ${[...dots.keys()].filter((sel) => sel.startsWith('.nav-file')).map((sel) => `${sel} .nav-file-tag`).join(',\n')} { order: 1; }` : '',
      ...DOTS.map((kind) => {
        const sels = [...dots].filter(([, k]) => k === kind).map(([sel]) => sel);
        if (!sels.length) return '';
        // A ring: the same outer size, border instead of fill
        return RINGS[kind]
          ? `${after(sels)} { box-sizing: border-box; border: var(--rock-sync-ring-width) solid var(${RINGS[kind]}); }`
          : `${after(sels)} { background-color: var(--rock-sync-dot-${kind}); }`;
      }),
      struck.length ? `${struck.join(',\n')} { text-decoration: line-through; color: var(--text-faint); }` : '',
      muted.length ? `${muted.join(',\n')} { color: var(--text-faint); }` : '',
    ].join('\n'));
  }
}
