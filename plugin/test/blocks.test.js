// Conflict labels: UTC in the working copy, this device's time zone on screen. Run: npm test
process.env.TZ = 'Europe/Moscow'; // UTC+3, no DST
import test from 'node:test';
import assert from 'node:assert/strict';
import { wholeFileConflict, serverDate } from '../src/conflicts/blocks.js';

test('serverDate: UTC label shown in local time', () => {
  assert.equal(serverDate('<<<<<<<<< server 2026-10-13T20:12Z'), '13.10 23:12');
  assert.equal(serverDate('<<<<<<<<< server 2026-12-31T22:30Z'), '01.01 01:30');
});

test('serverDate: label from before UTC labels, as written', () => {
  assert.equal(serverDate('<<<<<<<<< server 13.10.2026 20:12'), '13.10 20:12');
});

test('serverDate: no date', () => {
  assert.equal(serverDate('<<<<<<<<< server'), null);
});

test('wholeFileConflict: same label as the server writes', () => {
  assert.equal(
    wholeFileConflict('a', 'b\n', 'Tue, 13 Oct 2026 20:12:59 GMT'),
    '<<<<<<<<< server 2026-10-13T20:12Z\na\n=========\nb\n>>>>>>>>> mine\n'
  );
  assert.equal(serverDate(wholeFileConflict('a', 'b', 'Tue, 13 Oct 2026 20:12:59 GMT').split('\n')[0]), '13.10 23:12');
  assert.equal(wholeFileConflict('a\n', 'b\n', null).split('\n')[0], '<<<<<<<<< server');
});
