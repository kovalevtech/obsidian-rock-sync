// dd.mm.yyyy HH:MM, 24h, independent of the locale
const formatSavedAt = (savedAt) => {
  if (!savedAt) return 'unknown';
  const d = new Date(savedAt);
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
};

// dd.mm HH:MM
const formatShort = (iso) => formatSavedAt(iso).replace(/\.\d{4}/, '');

// 458 MB, 4.4 KB: binary units, one decimal below 10
const formatSize = (bytes) => {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let n = bytes;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i++;
  }
  return `${i && n < 10 ? n.toFixed(1) : Math.round(n)} ${units[i]}`;
};

export { formatSavedAt, formatShort, formatSize };
