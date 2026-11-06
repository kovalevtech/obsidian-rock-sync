import { requestUrl, Platform, apiVersion } from 'obsidian';
import { settings } from './settings.js';
import { debug } from './log.js';
import { encodePath, mergeable, syncable } from './paths.js';

// The running sync's token (vault-scoped localStorage, loaded / saved by Credentials) and this client's X-Rock-Sync-Client;
// endpoint and vault are in settings. onUnauthorized: the server refused them (401) — the plugin pauses sync.
// onAnswer: the server answered the running sync's credentials (sync status: last successful contact)
const session = { token: '', client: '', onUnauthorized: () => {}, onAnswer: () => {} };

const activeCredentials = () => ({ endpoint: settings.endpoint, vault: settings.vault, token: session.token });
const sameCredentials = (a, b) => a.endpoint === b.endpoint && a.vault === b.vault && a.token === b.token;

const PLATFORM = Platform.isAndroidApp ? 'android' : Platform.isIosApp ? 'ios'
  : Platform.isMacOS ? 'macos' : Platform.isWin ? 'windows' : Platform.isLinux ? 'linux' : 'unknown';
const clientInfo = (pluginVersion) => `plugin=${pluginVersion}; obsidian=${apiVersion}; platform=${PLATFORM}`;

// Basic: base64 of the UTF-8 bytes (btoa alone throws on non-Latin-1)
const base64 = (text) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));

// Every request carries them: vault + token as HTTP Basic, the client's software (never the device: that's the token).
// no-cache: requestUrl on desktop goes through Chromium's HTTP cache, which would answer with a version it holds, the
// server not asked (the server's no-store keeps new answers out of it; this skips what an older server's left there)
// X-Rock-Sync-Vault: Basic's vault in the clear, for a proxy in front (Cloudflare) that filters by it; the server
// refuses it when it differs from Basic's. Not for an empty vault (GET /vaults)
const authHeaders = ({ vault, token }) => ({
  Authorization: `Basic ${base64(`${vault}:${token}`)}`,
  ...(vault ? { 'X-Rock-Sync-Vault': vault } : {}),
  'X-Rock-Sync-Client': session.client,
  'Cache-Control': 'no-cache',
});

// Header names lowercased, as the code reads them: Android's requestUrl keeps them as sent (a Go proxy in front of
// the server sends `Etag`), desktop lowercases them. Without it every ETag is undefined there: polls without
// If-None-Match answered at once, in a loop
const lowerHeaders = (res) => Object.create(res, {
  headers: { value: Object.fromEntries(Object.entries(res.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v])) },
});

const fileUrl = (path) => `${settings.endpoint}/files/${encodePath(path)}`;

// The server merges only text/* (PUT on a stale If-Match, POST /merge); anything else gets 412 "nothing to merge"
const contentTypeOf = (path) => (mergeable(path) ? 'text/markdown' : 'application/octet-stream');

// Bytes a file may have to be downloaded, read or sent on this device. The mobile app passes request and response
// bodies through Java as base64 (several copies in a 256 MB heap): a 36 MB download crashed it on the Pixel (out of
// memory). Bigger files on the server become stubs here (sync.js)
const DEVICE_LIMIT = Platform.isMobile ? 20 * 1024 * 1024 : Infinity;

// GET /manifest in the format readManifest reads (v=1: with sizes; without v the server answers in the old format).
// query: more parameters (`&wait=25`)
const manifestUrl = (endpoint, query = '') => `${endpoint}/manifest?v=1${query}`;

// POST /pair: a one-time code + a device name → that device's token for the code's vault
const pairUrl = (endpoint) => `${endpoint}/pair`;

// DELETE /token: the token revokes itself (Remove, or a connection replaced)
const tokenUrl = (endpoint) => `${endpoint}/token`;

// GET /manifest's files ({ path: [hash, size] }), syncable paths only: { remote: path -> hash, sizes: path -> bytes }.
// A server from before sizes sends the hash alone (no size: nothing counts as too large for this device)
function readManifest(json) {
  const remote = {};
  const sizes = {};
  for (const [path, entry] of Object.entries(json.files)) {
    if (!syncable(path)) continue;
    const [hash, size] = Array.isArray(entry) ? entry : [entry];
    remote[path] = hash;
    sizes[path] = size;
  }
  return { remote, sizes };
}

const ATTEMPTS = 5;
const RETRY_DELAY = 5000; // ms, doubles after each failed attempt

const sleep = (ms, signal) => new Promise((resolve) => {
  const timer = window.setTimeout(resolve, ms);
  signal?.addEventListener('abort', () => { window.clearTimeout(timer); resolve(); }, { once: true });
});

class Unauthorized extends Error {}
// No answer after all attempts (offline, server down, 5xx): the poller shows that as offline, not as an error
class NoAnswer extends Error {}

// requestUrl with retries on network errors and 5xx; 4xx are final answers, not retried.
// Honors `throw: false` like requestUrl: then 4xx are returned instead of thrown.
// `signal` stops further retries; an attempt in flight can't be aborted (requestUrl has no abort).
// `credentials`: { vault, token } to try instead of the running sync's (settings check). A 401 for the running sync's
// own credentials always throws Unauthorized and pauses sync (onUnauthorized) — unless they were replaced meanwhile.
async function request({ signal, credentials, attempts = ATTEMPTS, ...opts }) {
  const label = `${opts.method ?? 'GET'} ${opts.url}`;
  const creds = credentials ?? activeCredentials();

  for (let attempt = 1; ; attempt++) {
    if (signal?.aborted) {
      debug(label, 'aborted before attempt', attempt);
      throw new Error(`${label} aborted`);
    }

    debug(label, 'attempt', attempt, opts.headers ?? {}); // not the auth headers
    const started = Date.now();
    let res, error;
    try {
      res = lowerHeaders(await requestUrl({ ...opts, headers: { ...opts.headers, ...authHeaders(creds) }, throw: false }));
    } catch (e) {
      error = e; // network failure: requestUrl rejects even with throw: false
    }
    debug(label, '->', res ? res.status : `error: ${error}`, `${Date.now() - started}ms`);

    if (res?.status === 401 && !credentials) {
      if (sameCredentials(creds, activeCredentials())) session.onUnauthorized();
      throw new Unauthorized(`${label}: wrong token or vault name`);
    }
    if (res && res.status < 500) {
      if (!credentials) session.onAnswer();
      if (res.status >= 400 && opts.throw !== false) throw new Error(`${label} failed: ${res.status}`);
      return res;
    }

    const reason = error ?? `status ${res.status}`;
    if (attempt >= attempts) throw new NoAnswer(`${label} failed after ${attempts} attempts: ${reason}`);

    const delay = RETRY_DELAY * 2 ** (attempt - 1);
    console.warn(`rock-sync: ${label} attempt ${attempt} failed (${reason}), retrying in ${delay}ms`);
    await sleep(delay, signal);
  }
}

// Commit time of the server version (Last-Modified) as an ISO string, null if not sent
const savedAtOf = (res) => (res.headers['last-modified'] ? new Date(res.headers['last-modified']).toISOString() : null);

export {
  session, activeCredentials, sameCredentials, clientInfo, authHeaders, lowerHeaders, fileUrl, contentTypeOf, DEVICE_LIMIT,
  manifestUrl, pairUrl, tokenUrl, readManifest, request, savedAtOf, Unauthorized, NoAnswer,
};
