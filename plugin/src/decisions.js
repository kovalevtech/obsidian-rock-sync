// The manifest check's decision table, for one path. Pure: hashes in, an action out; sync.js carries it out.
// local / remote / base: blob hashes, undefined when missing. conflict: the open conflict ({ serverHash }) or
// undefined. deleted: marked deleted on another device, waiting for Delete / Keep. review: the path's review mark from
// the first sync ('local' | 'differs'), firstSync: this check is the first after a rebind (base is empty).
// Returns [action, reason]: action is 'none' | 'refresh' | 'in-sync' | 'drop-base' | 'mark-deleted' | 'delete' |
// 'pull' | 'push' | 'review-local' | 'review-differs'. Any action but review-* drops a review mark; in-sync sets base.
function decide({ local, remote, base, conflict, deleted, review, firstSync = false }) {
  // Conflicted: never pushed or pulled; only keep its stored server version current
  if (conflict) {
    // Deleted on another device (a rename there is applied before the table): the conflict ends, my text stays,
    // marked like any deletion from elsewhere
    if (!remote) return local ? ['mark-deleted', 'conflict, deleted on another device'] : ['drop-base', 'conflict, gone on both sides'];
    return remote !== conflict.serverHash
      ? ['refresh', 'conflict, server version changed']
      : ['none', 'conflict'];
  }
  if (deleted) return ['none', 'deleted on another device, waits for Delete / Keep'];

  if (local && local === remote) return ['in-sync', review ? 'review: identical now' : 'in sync'];

  // First sync after a rebind (no base anywhere), and the paths it marked: nothing goes up without the user's say.
  // A review path gone here loses its mark and goes the normal way (server only: pulled)
  if (local && !base && (firstSync || review)) {
    return remote ? ['review-differs', 'review: differs from the server'] : ['review-local', 'review: not on the server'];
  }

  // Gone on the server since I synced it — whether or not I changed it here: never deleted here unconfirmed
  if (base && !remote) {
    return local ? ['mark-deleted', 'deleted on another device, mark'] : ['drop-base', 'gone on both sides'];
  }
  // Gone here since I synced it: deleted while the plugin wasn't running (edited on the server: the DELETE gets 412
  // and brings that version back, marked)
  if (base && !local) return ['delete', 'deleted here, delete on the server'];
  if (!local && !remote) return ['none', 'gone on both sides (a review mark only)'];
  if (!local) return ['pull', 'pull (remote only)'];
  if (local === base && remote !== base) return ['pull', 'pull (remote changed)'];
  // Remote untouched since last sync (or new local file): local version wins
  if (remote === base) return ['push', 'push (local changed)'];
  // Both changed since base (or both created): push with If-Match = base, the server tries a 3-way merge
  return ['push', 'push for merge (both changed)'];
}

// Does a manifest from the server need a full check here? Not when it's what this device already has: every path's
// hash equals base (for an open conflict: the server version it was merged against). Own pushes move the manifest's
// version too, and a full check hashes every local file. remote: syncable paths only.
function manifestChanged(remote, base, conflicts = {}) {
  const expected = { ...base };
  for (const [path, conflict] of Object.entries(conflicts)) expected[path] = conflict.serverHash;
  for (const path of new Set([...Object.keys(remote), ...Object.keys(expected)])) {
    if (remote[path] !== expected[path]) return true;
  }
  return false;
}

// Both sides of a manifest without a base (credentials check; the first sync after a rebind): paths by how they
// compare. local / remote: path -> hash (remote: syncable paths only)
function compareManifests(local, remote) {
  const result = { identical: [], localOnly: [], remoteOnly: [], differs: [] };
  for (const path of new Set([...Object.keys(local), ...Object.keys(remote)])) {
    if (!remote[path]) result.localOnly.push(path);
    else if (!local[path]) result.remoteOnly.push(path);
    else result[local[path] === remote[path] ? 'identical' : 'differs'].push(path);
  }
  return result;
}

export { decide, manifestChanged, compareManifests };
