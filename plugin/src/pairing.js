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

export { codeOf, isCode, linkOf, deviceNameOf, defaultDeviceName };
