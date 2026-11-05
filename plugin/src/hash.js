// git blob hash: sha1("blob <size>\0" + content), same as server side. bytes: ArrayBuffer or Uint8Array — always the
// file's raw bytes (readBinary), never decoded text: decoding drops a BOM, and the hash would no longer match the server's
async function gitBlobHash(bytes) {
  const header = new TextEncoder().encode(`blob ${bytes.byteLength}\0`);
  const buf = new Uint8Array(header.length + bytes.byteLength);
  buf.set(header);
  buf.set(new Uint8Array(bytes), header.length);
  const digest = await crypto.subtle.digest('SHA-1', buf);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Hash of empty content: every folder's `.keep`
const EMPTY_HASH = 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391';

export { gitBlobHash, EMPTY_HASH };
