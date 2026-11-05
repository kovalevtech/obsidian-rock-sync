// Conflict blocks in a working copy: git merge-file's markers. Pure: no obsidian, no CodeMirror (doc = any object
// with iterLines() / sliceString(), e.g. a CodeMirror Text)
import { formatShort } from '../format.js';

// git merge-file's format, as the server writes it (--marker-size=9, labels "server YYYY-MM-DDTHH:MMZ" / "mine": UTC,
// shown in the device's time zone)
const MARKER_SIZE = 9;
const START = `${'<'.repeat(MARKER_SIZE)} server`;
const MID = '='.repeat(MARKER_SIZE);
const END = `${'>'.repeat(MARKER_SIZE)} mine`;
const hasMarkers = (text) => text.split('\n').some((line) => line.startsWith(START));

const withNewline = (text) => (text === '' || text.endsWith('\n') ? text : `${text}\n`);

// The label's time, as the server writes it
const utcMinutes = (savedAt) => `${new Date(savedAt).toISOString().slice(0, 16)}Z`;

// The server couldn't merge (base unknown, binary, create-only clash): the whole file is one block
const wholeFileConflict = (server, mine, savedAt) => (
  `${savedAt ? `${START} ${utcMinutes(savedAt)}` : START}\n${withNewline(server)}${MID}\n${withNewline(mine)}${END}\n`
);

// Blocks: { start, mid, end } marker lines ({ from, to, text }); mid null = Result (the separator was deleted, one
// text). Incomplete blocks are ignored.
function findBlocks(doc) {
  const blocks = [];
  let start = null;
  let mid = null;
  let pos = 0;
  for (const text of doc.iterLines()) {
    const line = { from: pos, to: pos + text.length, text };
    pos = line.to + 1;
    if (text.startsWith(START)) [start, mid] = [line, null];
    else if (start && !mid && text === MID) mid = line;
    else if (start && text === END) {
      blocks.push({ start, mid, end: line });
      [start, mid] = [null, null];
    }
  }
  return blocks;
}

// Text of a block's sides, each with its trailing newline; a Result's text is its server side
const serverText = (doc, b) => doc.sliceString(b.start.to + 1, b.mid ? b.mid.from : b.end.from);
const mineText = (doc, b) => (b.mid ? doc.sliceString(b.mid.to + 1, b.end.from) : '');

// "dd.mm HH:MM" in this device's time zone from the start marker's label ("server YYYY-MM-DDTHH:MMZ"); null if it has
// no date. Working copies from before UTC labels ("server dd.mm.yyyy HH:MM", the server's local time): as written
const serverDate = (marker) => {
  const iso = marker.match(/\d{4}-\d\d-\d\dT\d\d:\d\dZ/);
  if (iso) return formatShort(iso[0]);
  const m = marker.match(/(\d\d\.\d\d)\.\d{4} (\d\d:\d\d)/);
  return m && `${m[1]} ${m[2]}`;
};

export { START, MID, END, hasMarkers, wholeFileConflict, findBlocks, serverText, mineText, serverDate };
