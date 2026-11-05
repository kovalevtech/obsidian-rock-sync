// The one sync queue, owned by the plugin (`plugin.queue`). Items are `op:path` keys (move: `op:from→to`), run one at
// a time; the ops themselves are registered by the subsystems (name → function(path, signal, to))
import { debug } from './log.js';

// Ops that change the server: their paths aren't synced until they ran (the grey dot)
const SENDING = new Set(['push', 'delete', 'move']);

export default class Queue {
  // onChange: called whenever an item is added, starts or ends. onError(item, error): an item failed (not aborted)
  constructor({ onChange = () => {}, onError = () => {} } = {}) {
    this.items = []; // { op, path, to, key }, waiting
    this.waiting = new Set(); // keys queued but not started
    this.current = null; // { item, controller } of the running item
    this.ops = {}; // op name -> run function
    this.paused = false; // items wait (sync paused: no / wrong credentials)
    this.onChange = onChange;
    this.onError = onError;
  }

  // Items waiting or running
  size() {
    return this.items.length + (this.current ? 1 : 0);
  }

  register(name, run) {
    this.ops[name] = run;
  }

  // Hot reload: the old instance must not keep sending alongside the new one
  stop() {
    this.clear();
    this.current?.controller.abort();
  }

  clear() {
    this.items.length = 0;
    this.waiting.clear();
    this.onChange();
  }

  // Resolves when the running item (if any) is done: a request in flight can't be aborted
  idle() {
    return this.running ? this.drained : Promise.resolve();
  }

  // Items stay queued; the running one is aborted and runs again first on resume (its answer may be the 401 that paused)
  pause() {
    this.paused = true;
    if (this.current) {
      this.current.interrupted = true;
      this.current.controller.abort();
    }
  }

  resume() {
    this.paused = false;
    this.drain();
  }

  // to: move's target path
  enqueue(op, path = '', to = null) {
    const key = to ? `${op}:${path}→${to}` : `${op}:${path}`;
    // Same item already running: drop its pending retries, the queued copy redoes it with fresh state
    if (this.current?.item.key === key) this.current.controller.abort();
    if (this.waiting.has(key)) return debug('already queued', key);

    this.waiting.add(key);
    this.items.push({ op, path, to, key });
    debug('enqueued', key, { queued: this.items.length });
    this.onChange();
    this.drain();
  }

  // Paths a queued or running push / delete / move will send (both paths of a move)
  pending() {
    const paths = new Set();
    for (const { op, path, to } of [...this.items, ...(this.current ? [this.current.item] : [])]) {
      if (!SENDING.has(op)) continue;
      paths.add(path);
      if (to) paths.add(to);
    }
    return paths;
  }

  drain() {
    if (this.running) return;
    this.running = true; // reset in the same tick the loop ends: an item enqueued right after starts a new drain
    this.drained = this.runAll();
  }

  async runAll() {
    try {
      while (this.items.length && !this.paused) {
        const item = this.items.shift();
        this.waiting.delete(item.key); // from now on a new modify re-queues it
        const controller = new AbortController();
        const current = { item, controller, interrupted: false };
        this.current = current;
        try {
          await this.run(item, controller.signal);
        } catch (e) {
          if (controller.signal.aborted) debug('aborted', item.key);
          else {
            console.error('rock-sync: failed', item.key, e);
            this.onError(item, e);
          }
        } finally {
          this.current = null;
          if (current.interrupted && !this.waiting.has(item.key)) {
            this.items.unshift(item);
            this.waiting.add(item.key);
          }
          this.onChange();
        }
      }
    } finally {
      this.running = false;
    }
  }

  run({ op, path, to }, signal) {
    const run = this.ops[op];
    if (!run) throw new Error(`unknown op ${op}`);
    return run(path, signal, to);
  }
}
