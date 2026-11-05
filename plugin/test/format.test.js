// Formatting helpers. Run: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import { formatSize } from '../src/format.js';

test('formatSize', () => {
  assert.equal(formatSize(0), '0 B');
  assert.equal(formatSize(1023), '1023 B');
  assert.equal(formatSize(4510), '4.4 KB');
  assert.equal(formatSize(81486), '80 KB');
  assert.equal(formatSize(105906176), '101 MB');
  assert.equal(formatSize(480496056), '458 MB');
  assert.equal(formatSize(5 * 1024 ** 3), '5.0 GB');
});
