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
