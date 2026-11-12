// Long polling: GET /manifest?wait=… with If-None-Match = the manifest version this device last saw. The server
// answers on its next commit (200 + manifest) or when the wait is over (304); either way we ask again right away.
// A manifest that differs from what this device has (manifestChanged) queues a full manifest check; so does the first
// answer after failures (back online: edits made meanwhile go up, failed pushes are retried).
// A 401 pauses sync (stops the poller too) unless the credentials were replaced while the poll was waiting.
// A poll this device left behind (a window closed or reloaded: the desktop app finishes its requests anyway) holds
// nothing up: the server ends a token's older poll when its next one comes.
// The first subsystem as a class the plugin owns (see CLAUDE.md "Architecture direction"): this.poller.
import { requestUrl } from 'obsidian';
import { session, activeCredentials, sameCredentials, authHeaders, lowerHeaders, manifestUrl, readManifest } from './api.js';
import { debug } from './log.js';
import { manifestChanged } from './decisions.js';

const WAIT = 25; // s the server holds a poll; below mobile requestUrl's own timeout
const RETRY_DELAY = 5000; // ms after a failed poll (offline, server down), doubling
const MAX_RETRY_DELAY = 60000;

export default class Poller {
  constructor(plugin) {
    this.plugin = plugin;
    this.running = false;
    this.loops = 0; // a loop whose poll is still in flight after stop() + start() ends instead of running alongside
    this.failures = 0; // polls failed in a row: > 0 = offline (sync status)
    this.problem = null; // while failures > 0: { text: why the last poll failed, retryAt: Date of the next one | null (now) }
    this.wakeUp = null; // ends the back-off wait after a failure
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.loop(++this.loops);
  }

  // A poll in flight can't be aborted (requestUrl): its answer is dropped
  stop() {
    this.running = false;
    this.setFailures(0); // not polling: neither online nor offline
    this.wake();
  }

  setFailures(n) {
    if (!n) this.problem = null;
    if (n === this.failures) return;
    this.failures = n;
    this.plugin.status.update();
  }

  // Don't sit out a back-off (the app is back in the foreground, Sync now): poll right away
  wake() {
    this.wakeUp?.();
  }

  async loop(id) {
    const live = () => this.running && id === this.loops;
    while (live()) {
      const etag = this.plugin.manifestEtag;
      const creds = activeCredentials();
      const started = Date.now();
      let res = null;
      let error = null;
      try {
        res = lowerHeaders(await requestUrl({
          url: manifestUrl(creds.endpoint, `&wait=${WAIT}`),
          headers: { ...(etag ? { 'If-None-Match': etag } : {}), ...authHeaders(creds) },
          throw: false,
        }));
      } catch (e) {
        error = e; // network
        debug('poll failed', String(e));
      }
      if (!live()) return;
      if (res?.status === 401) {
        if (sameCredentials(creds, activeCredentials())) return session.onUnauthorized(); // stops this loop
        continue; // replaced while waiting: ask again with the new ones
      }

      // 304 only comes when the wait is over; right away means the server (or a proxy) doesn't hold polls:
      // don't spin, back off like a failure
      const answered = (res?.status === 304 && Date.now() - started > 1000) || res?.status === 200;
      if (answered) session.onAnswer();
      if (answered && this.failures) {
        debug('poll: back online after', this.failures, 'failures');
        this.plugin.queue.enqueue('manifest');
      }
      if (res?.status === 304 && Date.now() - started > 1000) {
        this.setFailures(0);
        continue;
      }
      // No version to wait past: the next poll would be answered at once, and so on — back off like a failure
      if (res?.status === 200 && !res.headers['etag']) console.warn('rock-sync: poll answered without an ETag');
      else if (res?.status === 200) {
        this.setFailures(0);
        this.plugin.manifestEtag = res.headers['etag'];
        const { remote } = readManifest(res.json);
        if (manifestChanged(remote, this.plugin.base, this.plugin.conflicts)) {
          debug('poll: manifest changed', res.json.version);
          this.plugin.queue.enqueue('manifest');
        } else debug('poll: manifest moved, nothing new here', res.json.version);
        continue;
      }

      const failures = this.failures + 1;
      const delay = Math.min(RETRY_DELAY * 2 ** (failures - 1), MAX_RETRY_DELAY);
      this.problem = { text: problemOf(res, error), retryAt: new Date(Date.now() + delay) };
      debug('poll: retrying in', delay, this.problem.text);
      this.setFailures(failures);
      await new Promise((resolve) => {
        const timer = window.setTimeout(resolve, delay);
        this.wakeUp = () => { window.clearTimeout(timer); resolve(); };
      });
      this.wakeUp = null;
      if (live() && this.problem) {
        this.problem.retryAt = null;
        this.plugin.status.update();
      }
    }
  }
}

// Why a poll failed, for the sync status: the server may well have answered
function problemOf(res, error) {
  if (!res) return `No connection to the server: ${error?.message ?? error ?? 'no answer'}`;
  if (res.status === 429) return 'The server refused the poll: too many waiting (429)';
  if (res.status === 304) return 'The server answered at once instead of holding the poll: a proxy in front?';
  if (res.status === 200) return 'The server answered without an ETag';
  return `The server answered ${res.status}`;
}
