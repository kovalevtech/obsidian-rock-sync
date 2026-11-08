// Connecting with a one-time code (Credentials.pair): what's typed, and the name the device offers. Pure

const NAME_MAX = 64; // the server's: [a-z0-9-], at most 64

// The code as the server issues it: 6 digits, spaces as shown in the admin panel allowed
const codeOf = (typed) => typed.replace(/\s/g, '');
const isCode = (code) => /^\d{6}$/.test(code);

// The admin panel's connection link, <server URL>?code=123456, pasted into either field → { endpoint, code }, else null
const linkOf = (typed) => {
  let url;
  try {
    url = new URL(typed.trim());
  } catch {
    return null;
  }
  const code = codeOf(url.searchParams.get('code') || '');
  if (!/^https?:$/.test(url.protocol) || !isCode(code)) return null;
  return { endpoint: `${url.origin}${url.pathname}`.replace(/\/+$/, ''), code };
};

// A server URL that sends the token and the notes in the clear: plain http://, unless to this machine or over a tailnet
// (Tailscale's 100.64.0.0/10 and its *.ts.net names: WireGuard underneath). Not a URL at all: nothing to say yet
const insecure = (endpoint) => {
  let url;
  try {
    url = new URL(endpoint.trim());
  } catch {
    return false;
  }
  if (url.protocol !== 'http:') return false;
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (['localhost', '::1'].includes(host) || host.endsWith('.localhost') || host.endsWith('.ts.net')) return false;
  const ip = host.match(/^(\d+)\.(\d+)\.\d+\.\d+$/);
  return !(ip && (ip[1] === '127' || (ip[1] === '100' && Number(ip[2]) >= 64 && Number(ip[2]) <= 127)));
};

// What's typed → a name the server takes (the author of this device's commits): may be '' (nothing usable in it)
const deviceNameOf = (typed) => typed.toLowerCase()
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-+/, '')
  .slice(0, NAME_MAX)
  .replace(/-+$/, '');

// platform: Obsidian's Platform. deviceName and model aren't in its typings and may not be there: the kind of device is
// the fallback. A Mac's host name ends in .local
const defaultDeviceName = (platform) => {
  const known = deviceNameOf((platform.deviceName || platform.model || '').replace(/\.local$/, ''));
  if (known) return known;
  if (platform.isAndroidApp) return 'android';
  if (platform.isIosApp) return platform.isTablet ? 'ipad' : 'iphone';
  return platform.isMacOS ? 'mac' : platform.isWin ? 'windows' : platform.isLinux ? 'linux' : 'device';
};

export { codeOf, isCode, linkOf, insecure, deviceNameOf, defaultDeviceName };
