import { getIcon, setIcon } from 'obsidian';

// The first of the names this Obsidian has (newer Lucide icons may be missing in older versions)
function setIconOf(el, names) {
  const name = names.find((n) => getIcon(n)) ?? names[names.length - 1];
  setIcon(el, name);
}

export { setIconOf };
