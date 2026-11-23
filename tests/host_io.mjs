import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, openSync, ftruncateSync, closeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { readText, MAX_INPUT_BYTES } from '../io.mjs';
const root = dirname(dirname(fileURLToPath(import.meta.url)));

function temporary(action) {
  const directory = mkdtempSync(join(tmpdir(), 'moonpathspec-io-'));
  try { action(join(directory, 'input')); }
  finally { rmSync(directory, { recursive: true, force: true }); }
}

test('UTF-8 character split across read chunks is preserved', () => temporary(path => {
  const text = 'a'.repeat(65535) + '猫\r\nb';
  writeFileSync(path, text);
  assert.equal(readText(path), text);
}));

test('exactly 16 MiB is accepted and one extra byte is rejected', () => temporary(path => {
  writeFileSync(path, 'a'.repeat(MAX_INPUT_BYTES));
  assert.equal(readText(path).length, MAX_INPUT_BYTES);
  writeFileSync(path, 'a'.repeat(MAX_INPUT_BYTES + 1));
  assert.throws(() => readText(path), /exceeds 16 MiB/);
}));

test('large sparse input fails with a bounded read and structured CLI error', () => temporary(path => {
  const fd = openSync(path, 'w');
  try { ftruncateSync(fd, 128 * 1024 * 1024); } finally { closeSync(fd); }
  const result = spawnSync(process.execPath, ['cli.mjs', '--json', '--input', path], {
    cwd: root, encoding: 'utf8', timeout: 30000,
  });
  assert.equal(result.status, 2, result.stderr);
  const response = JSON.parse(result.stdout);
  assert.equal(response.error.code, 'host_error');
  assert.match(response.error.message, /exceeds 16 MiB/);
  assert.deepEqual(response.selected, []);
}));

test('oversize stdin is rejected using the same byte limit', () => {
  const result = spawnSync(process.execPath, ['cli.mjs', '--json', '--input', '-'], {
    cwd: root, input: Buffer.alloc(MAX_INPUT_BYTES + 1, 0x20), encoding: 'utf8', timeout: 30000,
  });
  assert.equal(result.status, 2, result.stderr);
  assert.match(JSON.parse(result.stdout).error.message, /exceeds 16 MiB/);
});

test('invalid UTF-8 at a chunk boundary is rejected', () => temporary(path => {
  writeFileSync(path, Buffer.concat([Buffer.alloc(65535, 0x61), Buffer.from([0xe7, 0x8c])]));
  assert.throws(() => readText(path), /encoded data|encoding/i);
}));

test('empty file reads cleanly after an earlier oversized failure', () => temporary(path => {
  writeFileSync(path, Buffer.alloc(MAX_INPUT_BYTES + 1));
  assert.throws(() => readText(path), /exceeds/);
  writeFileSync(path, '');
  assert.equal(readText(path), '');
}));
