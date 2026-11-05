// Hashes over raw bytes, identical to git's (and the server's); exact text for notes. Run: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import { gitBlobHash, EMPTY_HASH } from '../src/hash.js';
import { exactText } from '../src/text.js';

const bytes = (...parts) => Buffer.concat(parts.map((p) => (typeof p === 'string' ? Buffer.from(p) : Buffer.from(p))));
const BOM = [0xef, 0xbb, 0xbf];

test('gitBlobHash = git hash-object', async () => {
  assert.equal(await gitBlobHash(new ArrayBuffer(0)), EMPTY_HASH);
  // A note as before: text encoded as UTF-8
  assert.equal(await gitBlobHash(new TextEncoder().encode('# Title\n\nПривет, мир\n')), '037471849da51e23c22fa9d8feeb843f36cc9a91');
  // BOM and CRLF are part of the bytes
  assert.equal(await gitBlobHash(bytes(BOM, '# Title\r\n')), '6a65349d383772db8ee1ad0f146b80015e87c6e3');
  assert.equal(await gitBlobHash(bytes([0x00, 0xff, 0x10], 'binary')), 'beb9f871e06736f8514110aadb9866c19aea8a65');
});

test('gitBlobHash: ArrayBuffer and a Uint8Array view hash the same', async () => {
  const buf = new TextEncoder().encode('xx# Title\n').buffer;
  const view = new Uint8Array(buf, 2);
  assert.equal(await gitBlobHash(view), await gitBlobHash(buf.slice(2)));
});

test('exactText: round-trips to the same bytes, BOM included; not UTF-8 → null', () => {
  const withBom = bytes(BOM, '# Title\r\nПривет\n');
  const text = exactText(withBom);
  assert.equal(text.charCodeAt(0), 0xfeff);
  assert.deepEqual(Buffer.from(new TextEncoder().encode(text)), withBom);
  assert.equal(exactText(bytes([0x61, 0xff, 0x62])), null);
  assert.equal(exactText(new ArrayBuffer(0)), '');
});
