// Bytes ↔ text for notes written through Obsidian's text APIs, without changing a byte
const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

// The text that encodes back to exactly these bytes (a BOM kept as U+FEFF, which vault.modify writes back), or null
// (not UTF-8): such a file goes through the binary APIs
function exactText(bytes) {
  try {
    return decoder.decode(bytes);
  } catch {
    return null;
  }
}

export { exactText };
