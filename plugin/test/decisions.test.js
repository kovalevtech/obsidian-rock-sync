// Every row of the manifest decision table (CLAUDE.md "Client sync algorithm"). Run: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import { decide, manifestChanged, compareManifests } from '../src/decisions.js';

const A = 'a'.repeat(40);
const B = 'b'.repeat(40);
const C = 'c'.repeat(40);
const action = (state) => decide(state)[0];

test('conflict: refresh only when the server version moved on', () => {
  assert.equal(action({ local: A, remote: C, base: A, conflict: { serverHash: B } }), 'refresh');
  assert.equal(action({ local: A, remote: B, base: A, conflict: { serverHash: B } }), 'none');
  assert.equal(action({ local: A, remote: C, base: A, conflict: { serverHash: null } }), 'refresh'); // working copy lost
});

test('conflict, gone on the server: ends, my text marked deleted', () => {
  assert.equal(action({ local: A, remote: undefined, base: A, conflict: { serverHash: B } }), 'mark-deleted');
  assert.equal(action({ local: A, remote: undefined, base: undefined, conflict: { serverHash: B } }), 'mark-deleted');
  assert.equal(action({ local: undefined, remote: undefined, base: A, conflict: { serverHash: B } }), 'drop-base');
});

test('marked deleted: nothing until Delete / Keep, whatever the hashes', () => {
  assert.equal(action({ local: A, remote: undefined, base: undefined, deleted: true }), 'none');
  assert.equal(action({ local: A, remote: B, base: undefined, deleted: true }), 'none');
});

test('local = remote: in sync (base set)', () => {
  assert.equal(action({ local: A, remote: A, base: undefined }), 'in-sync');
  assert.equal(action({ local: A, remote: A, base: B }), 'in-sync');
});

test('in base, gone on the server: mark deleted, changed here or not', () => {
  assert.equal(action({ local: A, remote: undefined, base: A }), 'mark-deleted');
  assert.equal(action({ local: B, remote: undefined, base: A }), 'mark-deleted');
});

test('in base, gone on both: drop base', () => {
  assert.equal(action({ local: undefined, remote: undefined, base: A }), 'drop-base');
});

test('in base, gone here: DELETE (unchanged on the server or not — 412 restores)', () => {
  assert.equal(action({ local: undefined, remote: A, base: A }), 'delete');
  assert.equal(action({ local: undefined, remote: B, base: A }), 'delete');
});

test('server only: pull', () => {
  assert.equal(action({ local: undefined, remote: A, base: undefined }), 'pull');
});

test('local = base, remote changed: pull', () => {
  assert.equal(action({ local: A, remote: B, base: A }), 'pull');
});

test('remote = base, local changed / no base, local only: push', () => {
  assert.equal(action({ local: B, remote: A, base: A }), 'push');
  assert.equal(action({ local: A, remote: undefined, base: undefined }), 'push');
  assert.match(decide({ local: B, remote: A, base: A })[1], /local changed/);
});

test('both changed / both created: push for the server merge', () => {
  assert.deepEqual(decide({ local: B, remote: C, base: A }), ['push', 'push for merge (both changed)']);
  assert.deepEqual(decide({ local: B, remote: C, base: undefined }), ['push', 'push for merge (both changed)']);
});

test('manifestChanged: only what this device doesn\'t have yet', () => {
  assert.equal(manifestChanged({ 'a.md': A }, { 'a.md': A }), false); // e.g. my own push
  assert.equal(manifestChanged({ 'a.md': B }, { 'a.md': A }), true); // edited elsewhere
  assert.equal(manifestChanged({ 'a.md': A, 'b.md': B }, { 'a.md': A }), true); // created elsewhere
  assert.equal(manifestChanged({}, { 'a.md': A }), true); // deleted elsewhere
  // Open conflict: compared with the server version it was merged against, not base
  assert.equal(manifestChanged({ 'a.md': B }, { 'a.md': A }, { 'a.md': { serverHash: B } }), false);
  assert.equal(manifestChanged({ 'a.md': C }, { 'a.md': A }, { 'a.md': { serverHash: B } }), true);
});

test('compareManifests: identical, only here, only on the server, different', () => {
  assert.deepEqual(
    compareManifests({ same: A, mine: B, both: A, 'f/.keep': C }, { same: A, theirs: C, both: B, 'f/.keep': C }),
    { identical: ['same', 'f/.keep'], localOnly: ['mine'], remoteOnly: ['theirs'], differs: ['both'] },
  );
  assert.deepEqual(compareManifests({}, {}), { identical: [], localOnly: [], remoteOnly: [], differs: [] });
});

test('first sync (empty base): identical → base, server only → pull, the rest to review', () => {
  const first = (state) => action({ ...state, firstSync: true });
  assert.equal(first({ local: A, remote: A }), 'in-sync');
  assert.equal(first({ local: undefined, remote: A }), 'pull');
  assert.equal(first({ local: A, remote: undefined }), 'review-local');
  assert.equal(first({ local: A, remote: B }), 'review-differs');
});

test('review marks: re-evaluated on every check, never pushed', () => {
  assert.equal(action({ local: A, remote: A, review: 'differs' }), 'in-sync');
  assert.equal(action({ local: A, remote: undefined, review: 'local' }), 'review-local');
  assert.equal(action({ local: A, remote: undefined, review: 'differs' }), 'review-local');
  assert.equal(action({ local: A, remote: B, review: 'local' }), 'review-differs');
  assert.equal(action({ local: A, remote: B, review: 'differs' }), 'review-differs');
});

test('review path gone here: mark dropped, the normal rules (server only → pull)', () => {
  assert.equal(action({ local: undefined, remote: B, review: 'differs' }), 'pull');
  assert.equal(action({ local: undefined, remote: undefined, review: 'local' }), 'none');
});

test('after the first sync, a new local file without base is pushed as usual', () => {
  assert.equal(action({ local: A, remote: undefined }), 'push');
  assert.equal(action({ local: A, remote: B }), 'push');
});
