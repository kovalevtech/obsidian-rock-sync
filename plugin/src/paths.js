// Sync paths: vault paths of synced files, plus `<folder>/.keep` for folders.
// Folders sync as `<folder>/.keep`: an empty file on the server, never created in the vault — the folder itself is
// the local side (its content is always empty, so its hash is the empty blob's, EMPTY_HASH in hash.js)
const KEEP = '.keep';
const isKeep = (path) => path.endsWith(`/${KEEP}`);
const keepOf = (folder) => `${folder}/${KEEP}`;
const folderOfKeep = (path) => path.slice(0, -(KEEP.length + 1));

// OS clutter, never synced
const IGNORED = new Set(['Thumbs.db', 'desktop.ini']);
const ignored = (path) => IGNORED.has(path.split('/').pop());

// Everything the vault API sees. Hidden (dot) paths — `.obsidian`, `.trash`, `.git` — it doesn't: never synced,
// whichever side has them (a pulled hidden file would never show up locally)
const hidden = (path) => (isKeep(path) ? folderOfKeep(path) : path).split('/').some((part) => part.startsWith('.'));
const syncable = (path) => !hidden(path) && !ignored(path);

// Notes: written through the text APIs (an open editor keeps its cursor)
const isMarkdown = (path) => path.toLowerCase().endsWith('.md');
// The only list of what the server may 3-way merge (sent as text/markdown; the rest as application/octet-stream).
// Excalidraw keeps compressed JSON on one line: markers would break it
const mergeable = (path) => isMarkdown(path) && !path.toLowerCase().endsWith('.excalidraw.md');

// Conflict copies (keep both, for files the server can't merge): `X (copy).ext`, `X (copy 2).ext`, … Recognized by
// name alone, on every device. A compound suffix stays whole: `Drawing (copy).excalidraw.md`
const COMPOUND_EXTS = ['.excalidraw.md'];
const COPY_SUFFIX = / \(copy(?: ([2-9]|[1-9]\d+))?\)$/;

// [dir with its slash, stem, extension with its dot]
function splitName(path) {
  const slash = path.lastIndexOf('/') + 1;
  const name = path.slice(slash);
  const compound = COMPOUND_EXTS.find((ext) => name.toLowerCase().endsWith(ext) && name.length > ext.length);
  const dot = compound ? name.length - compound.length : name.lastIndexOf('.');
  return dot > 0 ? [path.slice(0, slash), name.slice(0, dot), name.slice(dot)] : [path.slice(0, slash), name, ''];
}

// The original a copy's name points to (`X.ext`), or null. A copy only while that original exists
function copyOrigin(path) {
  const [dir, stem, ext] = splitName(path);
  const suffix = stem.match(COPY_SUFFIX);
  return suffix && suffix.index > 0 ? `${dir}${stem.slice(0, suffix.index)}${ext}` : null;
}

// First free copy name; a copy's copy is numbered after the original (`X (copy 2).ext`, not `X (copy) (copy).ext`)
function copyPath(path, exists) {
  const [dir, stem, ext] = splitName(copyOrigin(path) ?? path);
  for (let n = 1; ; n++) {
    const candidate = `${dir}${stem} (copy${n > 1 ? ` ${n}` : ''})${ext}`;
    if (!exists(candidate)) return candidate;
  }
}

const encodePath = (path) => path.split('/').map(encodeURIComponent).join('/');

export {
  KEEP, isKeep, keepOf, folderOfKeep, ignored, syncable, isMarkdown, mergeable, copyOrigin, copyPath, encodePath,
};
