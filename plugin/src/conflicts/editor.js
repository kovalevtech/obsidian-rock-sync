// The conflict editor's CodeMirror state: blocks parsed from the working copy, which edits are allowed (markers
// protected, the separator deleted only whole), the block cards (widgets, line bars) and their buttons
import { Platform, setIcon } from 'obsidian';
import { Decoration, EditorView, WidgetType } from '@codemirror/view';
import { Annotation, EditorState, StateField, Transaction } from '@codemirror/state';
import { findBlocks, serverText, mineText, serverDate } from './blocks.js';

// Our own decisions and reloads: they may touch marker lines and don't count as hand edits
const ownEdit = Annotation.define();

const conflictBlocks = StateField.define({
  create: (state) => findBlocks(state.doc),
  update: (blocks, tr) => (tr.docChanged ? findBlocks(tr.state.doc) : blocks),
});

// The blocks' texts as loaded: a block whose text differs is being merged by hand (its buttons collapse into a
// single checkmark); undoing back to the loaded text brings the choices back
const blockKey = (doc, b) => `${serverText(doc, b)}\u0000${mineText(doc, b)}`;
const loadedBlocks = StateField.define({
  create: (state) => new Set(findBlocks(state.doc).map((b) => blockKey(state.doc, b))),
  update: (keys) => keys,
});

const editedByHand = (state, b) => !state.field(loadedBlocks).has(blockKey(state.doc, b));

const userEdit = (tr) => !tr.annotation(ownEdit) && ['input', 'delete', 'move'].some((e) => tr.isUserEvent(e));

// Start and end markers, with the line breaks around them, can't be edited by hand: only the buttons remove them
const protectMarkers = EditorState.changeFilter.of((tr) => {
  if (!userEdit(tr)) return true;
  const ranges = [];
  const { length } = tr.startState.doc;
  for (const { start, end } of tr.startState.field(conflictBlocks)) {
    for (const [from, to] of [[Math.max(start.from - 1, 0), start.to + 1], [end.from - 1, Math.min(end.to + 1, length)]]) {
      // An empty block: the ranges touch, merge them (ranges must not overlap)
      if (ranges.length && from <= ranges[ranges.length - 1]) ranges[ranges.length - 1] = to;
      else ranges.push(from, to);
    }
  }
  return ranges;
});

// The separator may be deleted, but only whole, like a line break between my text and the server's: Backspace at the
// start of my side (or Delete at the end of the server side) joins the two lines, a selection across both sides
// removes it with the text. The block becomes a Result. Typing can't go into the separator line: next to it, it
// goes to the adjacent side. Covers what atomicRanges doesn't (Android's input reports raw DOM edits).
function separatorSpan(b, hiddenFrom) {
  // Never into the start / end markers' protected line breaks
  return [Math.max(hiddenFrom - 1, b.start.to + 1), Math.min(b.mid.to + 1, b.end.from - 1)];
}

const editSeparator = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || !userEdit(tr)) return tr;
  const changes = [];
  tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => changes.push({ fromA, toA, insert: inserted.toString() }));
  if (changes.length !== 1) return tr;
  const [{ fromA, toA, insert }] = changes;
  const userEvent = tr.annotation(Transaction.userEvent);
  const { hidden } = tr.startState.field(conflictDecorations);
  for (const b of tr.startState.field(conflictBlocks)) {
    if (!b.mid) continue;
    // Typing right at the separator line (an empty side): becomes a line of that side
    if (fromA === toA && fromA === b.mid.from) {
      return { changes: { from: fromA, insert: `${insert}\n` }, selection: { anchor: fromA + insert.length }, userEvent };
    }
    if (fromA === toA && fromA === b.mid.to) {
      return { changes: { from: fromA, insert: `\n${insert}` }, selection: { anchor: fromA + 1 + insert.length }, userEvent };
    }
    const [lo, hi] = separatorSpan(b, hidden.get(b.mid.from) ?? b.mid.from);
    if (toA <= lo || fromA >= hi || (fromA <= lo && toA >= hi)) continue; // outside, or already all of it
    const from = Math.min(fromA, lo);
    if (fromA === toA) return { changes: { from: hi, insert }, selection: { anchor: hi + insert.length }, userEvent };
    return { changes: { from, to: Math.max(toA, hi), insert }, selection: { anchor: from + insert.length }, userEvent };
  }
  return tr;
});

// Replace a whole block (markers included) with the chosen text; undoable like any edit
function decide(view, pos, choose) {
  const { doc } = view.state;
  const b = view.state.field(conflictBlocks).find((x) => x.start.from <= pos && pos <= x.end.to);
  if (!b) return;
  view.dispatch({
    changes: { from: b.start.from, to: Math.min(b.end.to + 1, doc.length), insert: choose(serverText(doc, b), mineText(doc, b)) },
    annotations: ownEdit.of(true),
    userEvent: 'input.decide',
  });
}

// Each block is one card (styles.css): widgets replacing the marker lines draw its top (first caption), the start
// of my side (mine caption) and its bottom (buttons); the lines in between carry the card's background and a bar.

// Replaces a marker line: the caption, first line inside its side's bar. Server / Result: also the card's top
class SideLabelWidget extends WidgetType {
  constructor(side, text) {
    super();
    this.side = side;
    this.text = text;
  }

  eq(other) { return other.side === this.side && other.text === this.text; }

  toDOM() {
    const wrap = createDiv({ cls: `rock-sync-label rock-sync-label-${this.side}` });
    const row = wrap.createDiv({ cls: 'rock-sync-card' }).createDiv({ cls: 'rock-sync-label-row' });
    const icon = { server: 'cloud', result: 'git-merge', mine: Platform.isMobile ? 'smartphone' : 'monitor' }[this.side];
    setIcon(row.createSpan({ cls: 'rock-sync-label-icon' }), icon);
    row.createSpan({ text: this.text });
    return wrap;
  }
}

// Replaces the end marker line (and the blank lines before it): the block's buttons, the card's bottom
class BlockButtonsWidget extends WidgetType {
  constructor(kind) {
    super();
    this.kind = kind; // 'choose' | 'done' (two sides, edited by hand) | 'result'
  }

  eq(other) { return other.kind === this.kind; }

  toDOM(view) {
    const wrap = createDiv({ cls: 'rock-sync-buttons' });
    const row = wrap.createDiv({ cls: 'rock-sync-card' });
    const button = (text, choose, title) => {
      const el = row.createEl('button', { text, attr: title ? { 'aria-label': title } : {} });
      // mousedown + preventDefault: no focus / selection jump before the decision
      el.addEventListener('mousedown', (e) => {
        e.preventDefault();
        decide(view, view.posAtDOM(wrap), choose);
      });
    };
    if (this.kind === 'choose') {
      button('Take server', (server) => server);
      button('Keep mine', (server, mine) => mine);
      button('Both', (server, mine) => server + mine);
    } else {
      // Merged by hand: the text stays as shown, only the markers go
      button('✓ Done', (server, mine) => server + mine, 'Keep the text of this part as it is now');
    }
    return wrap;
  }
}

// Server lines are someone else's text: no spellcheck squiggles
const serverLine = Decoration.line({ class: 'rock-sync-server-line', attributes: { spellcheck: 'false' } });
const mineLine = Decoration.line({ class: 'rock-sync-mine-line' });
const resultLine = Decoration.line({ class: 'rock-sync-result-line' });
const atomicMark = Decoration.mark({});

// { deco, atomic, hidden }: decorations; ranges the cursor skips (marker lines with the line breaks around them);
// mid marker position -> start of its widget (after the server side's hidden trailing blank lines)
const conflictDecorations = StateField.define({
  create: (state) => buildConflictDecorations(state),
  // Selection too: a trailing blank line with the cursor in it stays visible
  update: (value, tr) => (tr.docChanged || tr.selection ? buildConflictDecorations(tr.state) : value),
  provide: (field) => [
    EditorView.decorations.from(field, (value) => value.deco),
    EditorView.atomicRanges.of((view) => view.state.field(field).atomic),
  ],
});

function buildConflictDecorations(state) {
  const { doc } = state;
  const cursor = state.selection.main.head;
  const deco = [];
  const atomic = [];
  const hidden = new Map();
  // Lines from..to (exclusive) of one side get its bar. Trailing blank lines (except the first line, and one holding
  // the cursor) are hidden together with the marker after them: returns where that hidden range starts
  const side = (from, to, line) => {
    const lines = [];
    for (let pos = from; pos < to;) {
      const l = doc.lineAt(pos);
      lines.push(l);
      pos = l.to + 1;
    }
    let shown = lines.length;
    while (shown > 1 && lines[shown - 1].length === 0 && lines[shown - 1].from !== cursor) shown--;
    lines.slice(0, shown).forEach((l) => deco.push(line.range(l.from)));
    return shown < lines.length ? lines[shown].from : to;
  };
  const widget = (w, from, to, atomicFrom, atomicTo) => {
    deco.push(Decoration.replace({ block: true, widget: w }).range(from, to));
    if (atomicTo > atomicFrom) atomic.push(atomicMark.range(atomicFrom, atomicTo));
  };
  for (const b of state.field(conflictBlocks)) {
    const { start, mid, end } = b;
    const after = Math.min(end.to + 1, doc.length);
    if (mid) {
      const date = serverDate(start.text);
      widget(new SideLabelWidget('server', date ? `Server · ${date}` : 'Server'), start.from, start.to,
        Math.max(start.from - 1, 0), start.to + 1);
      const midFrom = side(start.to + 1, mid.from, serverLine);
      hidden.set(mid.from, midFrom);
      widget(new SideLabelWidget('mine', 'Mine'), midFrom, mid.to, ...separatorSpan(b, midFrom));
      const endFrom = side(mid.to + 1, end.from, mineLine);
      widget(new BlockButtonsWidget(editedByHand(state, b) ? 'done' : 'choose'), endFrom, end.to,
        Math.max(endFrom - 1, mid.to + 1), after);
    } else {
      widget(new SideLabelWidget('result', 'Result'), start.from, start.to, Math.max(start.from - 1, 0), start.to + 1);
      const endFrom = side(start.to + 1, end.from, resultLine);
      widget(new BlockButtonsWidget('result'), endFrom, end.to, Math.max(endFrom - 1, start.to + 1), after);
    }
  }
  return { deco: Decoration.set(deco, true), atomic: Decoration.set(atomic, true), hidden };
}

export { conflictBlocks, loadedBlocks, protectMarkers, editSeparator, conflictDecorations };
