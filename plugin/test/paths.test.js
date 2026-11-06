// What syncs, and what the server may merge. Run: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import { syncable, ignored, isMarkdown, mergeable } from '../src/paths.js';

test('syncable: every file type and folder', () => {
  for (const path of ['note.md', 'a/b/image.png', 'doc.pdf', 'x.yaml', 'a.zip', 'board.canvas', 'no-extension', 'a/b/.keep']) {
    assert.ok(syncable(path), path);
  }
});

test('syncable: hidden paths and OS clutter never', () => {
  for (const path of ['.obsidian/app.json', '.obsidian/plugins/x/data.json', '.trash/a.md', 'a/.git/config', '.hidden.md',
    '.plugins/x/data.json', '.dir/.keep', 'Thumbs.db', 'pics/Thumbs.db', 'a/desktop.ini']) {
    assert.ok(!syncable(path), path);
  }
  assert.ok(ignored('a/Thumbs.db'));
  assert.ok(!ignored('Thumbs.db.md'));
});

test('mergeable: markdown only, not excalidraw', () => {
  assert.ok(mergeable('a/note.md'));
  assert.ok(mergeable('NOTE.MD'));
  for (const path of ['d.excalidraw.md', 'D.Excalidraw.md', 'i.svg', 'b.canvas', 't.txt', 'p.png', 'md', 'x.mdx']) {
    assert.ok(!mergeable(path), path);
  }
  assert.ok(isMarkdown('d.excalidraw.md'));
  assert.ok(!isMarkdown('i.svg'));
});

import { copyPath, copyOrigin } from '../src/paths.js';

test('copyPath: first free name, extension kept', () => {
  const taken = (...paths) => (p) => paths.includes(p);
  assert.equal(copyPath('a/pic.png', taken()), 'a/pic (copy).png');
  assert.equal(copyPath('a/pic.png', taken('a/pic (copy).png')), 'a/pic (copy 2).png');
  assert.equal(copyPath('a/pic.png', taken('a/pic (copy).png', 'a/pic (copy 2).png')), 'a/pic (copy 3).png');
  assert.equal(copyPath('Makefile', taken()), 'Makefile (copy)');
  assert.equal(copyPath('a.b/arch.tar.gz', taken()), 'a.b/arch.tar (copy).gz');
  assert.equal(copyPath('Drawing.excalidraw.md', taken()), 'Drawing (copy).excalidraw.md');
  assert.equal(copyPath('D.Excalidraw.md', taken()), 'D (copy).Excalidraw.md');
  // A copy's own conflict: numbered after the original
  assert.equal(copyPath('pic (copy).png', taken('pic (copy).png')), 'pic (copy 2).png');
});

test('copyOrigin: by name only', () => {
  assert.equal(copyOrigin('a/pic (copy).png'), 'a/pic.png');
  assert.equal(copyOrigin('a/pic (copy 2).png'), 'a/pic.png');
  assert.equal(copyOrigin('a/pic (copy 12).png'), 'a/pic.png');
  assert.equal(copyOrigin('Drawing (copy 3).excalidraw.md'), 'Drawing.excalidraw.md');
  assert.equal(copyOrigin('Makefile (copy)'), 'Makefile');
  for (const path of ['pic.png', 'pic (copy 1).png', 'pic (copy 0).png', 'pic (Copy).png', 'pic(copy).png', ' (copy).png', 'pic (copy).png/x.png']) {
    assert.equal(copyOrigin(path), null, path);
  }
  for (const path of ['a/pic.png', 'Makefile', 'Drawing.excalidraw.md', 'x.tar.gz']) {
    assert.equal(copyOrigin(copyPath(path, () => false)), path);
  }
});

import { encodePath } from '../src/paths.js';

// The server refuses a request path that isn't canonical (backend/lib/canonical_path.rb, 400): this mirrors its rules.
// Every path the plugin can send must pass them, and decode back to the vault path
function canonical(path) {
  if (!path.startsWith('/') || path.includes('\\')) return false;
  if (/%(2f|5c|2e)/i.test(path) || /%(?![0-9a-f]{2})/i.test(path)) return false;
  const segments = path.slice(1).split('/');
  if (segments.at(-1) === '') segments.pop();
  if (segments.some((s) => s === '' || s === '.' || s === '..')) return false;
  const bytes = path.replace(/%([0-9a-f]{2})/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
  return !/\p{Cc}/u.test(new TextDecoder().decode(Uint8Array.from(bytes, (c) => c.charCodeAt(0))));
}

test('canonical: the mirror refuses what the server does', () => {
  for (const path of ['//a', '/a//b', '/a/./b', '/a/../b', '/a/.', '/a%2fb', '/a%2Fb', '/a%5cb', '/a%2eb', '/a\\b', '/a%00',
    '/a%0a', '/a%7f', '/a%c2%85', '/a%zz', '/a%', 'a', '*']) {
    assert.ok(!canonical(path), path);
  }
  for (const path of ['/', '/a/', '/files/%25.md', '/files/%252f.md', '/files/a..b.md', '/files/...', '/files/a/.keep']) {
    assert.ok(canonical(path), path);
  }
});

// Names Obsidian accepts (none has `/`, `\`, `:`); hidden ones never sync, but their encoding is checked too
const NASTY = [
  '%.md', '100%.md', '%2f.md', '%2F%2e%2E%5c.md', '%25.md', '%%.md', 'a..b.md', 'a.', 'x...md', '...', 'a/.../b.md',
  ' leading.md', 'trailing .md', ' both /  sides  .md', 'a#b.md', 'a?b.md', 'a;b.md', 'a+b.md', 'a&b=c.md', "it's (1)!.md",
  'a*b~c.md', '@$,[]^|<>"`{}.md', 'Заметка/Ёлка.md', 'Café.md', 'Café.md', '📝 note 👩‍💻.md', '日本語/ノート.md',
  'עברית.md', 'a b​c d.md', 'Drawing.excalidraw.md', 'folder/.keep', 'deep/a b/c#d/.keep',
];

test('encodePath: every request path the plugin sends is canonical and decodes back', () => {
  for (const endpoint of ['https://sync.example.com', 'https://example.com/sync']) {
    const prefix = new URL(endpoint).pathname.replace(/\/$/, '');
    for (const path of NASTY) {
      for (const route of ['files', 'move', 'merge']) {
        // What requestUrl puts on the wire: the URL as parsed (WHATWG would resolve dot segments, encode what's left)
        const { pathname } = new URL(`${endpoint}/${route}/${encodePath(path)}`);
        assert.ok(/^[\x21-\x7e]+$/.test(pathname), pathname);
        assert.ok(canonical(pathname), `${path} → ${pathname}`);
        assert.ok(pathname.startsWith(`${prefix}/${route}/`), pathname);
        assert.equal(decodeURIComponent(pathname.slice(`${prefix}/${route}/`.length)), path);
      }
      // Destination (POST /move): decoded whole by the server (URI.decode_uri_component)
      assert.equal(decodeURIComponent(encodePath(path)), path);
    }
  }
});
