import test from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, appendFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
function run(script) {
  return spawnSync(process.execPath, [script], { cwd: root, encoding: 'utf8', timeout: 30000 });
}
function packageFiles() {
  const result = run('scripts/package.mjs');
  assert.equal(result.status, 0, result.stderr);
}

test('distribution rejects extra or tampered files and rebuilding restores a clean package', () => {
  packageFiles();
  try {
    assert.equal(run('scripts/check-dist.mjs').status, 0);
    const stale = new URL('../dist/stale.txt', import.meta.url);
    writeFileSync(stale, 'old build data');
    assert.notEqual(run('scripts/check-dist.mjs').status, 0);
    packageFiles();
    assert.equal(existsSync(stale), false);
    appendFileSync(new URL('../dist/host.mjs', import.meta.url), '\n// changed after packaging\n');
    assert.notEqual(run('scripts/check-dist.mjs').status, 0);
  } finally {
    packageFiles();
  }
  assert.equal(run('scripts/check-dist.mjs').status, 0);
});
