import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, copyFileSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';

test('missing toolchain replaces stale passed evidence with this failed run', () => {
  const root=mkdtempSync(join(tmpdir(),'moonpathspec-verification-'));
  try {
    mkdirSync(join(root,'scripts'));
    mkdirSync(join(root,'evidence/local'),{recursive:true});
    copyFileSync(new URL('../scripts/verify.mjs',import.meta.url),join(root,'scripts/verify.mjs'));
    writeFileSync(join(root,'evidence/local/verification.json'),JSON.stringify({passed:true,status:'passed',run_id:'old'}));
    const result=spawnSync(process.execPath,['scripts/verify.mjs'],{cwd:root,encoding:'utf8',timeout:30000,
      env:{...process.env,MOONPATHSPEC_MOON:join(root,'absent-moon')}});
    assert.equal(result.status,2);
    const record=JSON.parse(readFileSync(join(root,'evidence/local/verification.json'),'utf8'));
    assert.equal(record.passed,false);
    assert.equal(record.status,'failed');
    assert.notEqual(record.run_id,'old');
    assert.equal(record.steps[0].step,'toolchain version');
    assert.equal(record.steps[0].exit_code,2);
    assert.ok(Date.parse(record.started_at));
  } finally { rmSync(root,{recursive:true,force:true}); }
});
