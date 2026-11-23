import { openSync, readSync, closeSync } from 'node:fs';

export const MAX_INPUT_BYTES = 16 * 1024 * 1024;

// Read at most the limit plus one sentinel byte, including when stdin is a pipe.
// The size limit must apply before allocating the complete input file.
export function readText(path) {
  const fd = path === '-' ? 0 : openSync(path, 'r');
  const chunks = [];
  let total = 0;
  try {
    while (total <= MAX_INPUT_BYTES) {
      const chunk = Buffer.allocUnsafe(Math.min(64 * 1024, MAX_INPUT_BYTES + 1 - total));
      const count = readSync(fd, chunk, 0, chunk.length, null);
      if (count === 0) break;
      total += count;
      if (total > MAX_INPUT_BYTES) throw new Error('File exceeds 16 MiB');
      chunks.push(chunk.subarray(0, count));
    }
    return new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, total));
  } finally {
    if (path !== '-') closeSync(fd);
  }
}
