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

// Code points HFS+ ignores in names (the server's Vault::Path::HFS_IGNORED): `.<U+200C>obsidian` is `.obsidian` there
const HFS_IGNORED = /[\u200c-\u200f\u202a-\u202e\u206a-\u206f\ufeff]/g;

// Everything the vault API sees. Hidden (dot) paths — `.obsidian`, `.trash`, `.git` — it doesn't: never synced,
// whichever side has them (a pulled hidden file would never show up locally)
const hidden = (path) => (isKeep(path) ? folderOfKeep(path) : path).split('/')
  .some((part) => part.replace(HFS_IGNORED, '').startsWith('.'));
const syncable = (path) => !hidden(path) && !ignored(path);

// A path the server may hand us (the manifest's keys): the server's own rule (Vault::Path) mirrored, hidden segments
// left to syncable(). Anything else never came from a real server — and Obsidian's API wouldn't stop it: its
// normalizePath turns `\` into `/` and keeps `..`, the desktop adapter joins that onto the vault's folder, so
// `a\..\..\x` is written outside the vault
const utf8Length = (text) => new TextEncoder().encode(text).length;
const NTFS_DOTGIT = /^git~1[ .]*(:|$)/i;
const validPath = (path) => typeof path === 'string'
  && utf8Length(path) <= 1024
  && !/[\p{Cc}\p{Cs}\\]/u.test(path) // control characters, a lone surrogate, a backslash
  && !path.startsWith('~')
  && path.split('/').every((part) => part && part !== '.' && part !== '..' && utf8Length(part) <= 255
    && !NTFS_DOTGIT.test(part));

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
  KEEP, isKeep, keepOf, folderOfKeep, ignored, syncable, validPath, isMarkdown, mergeable, copyOrigin, copyPath, encodePath,
};
