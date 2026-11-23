import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const root=dirname(dirname(fileURLToPath(import.meta.url)));
const folder=mkdtempSync(join(tmpdir(),'moonpathspec-dist-'));
try {
  cpSync(join(root,'dist'),folder,{recursive:true});
  const request={patterns:[':(glob)**/*.mbt',':(exclude)vendor'],paths:['main.mbt','src/a.mbt','vendor/a.mbt','README.md']};
  const result=spawnSync(process.execPath,['cli.mjs','--input','-','--json'],{cwd:folder,input:JSON.stringify(request),encoding:'utf8',timeout:30000});
  assert.equal(result.status,0,result.stderr);
  assert.deepEqual(JSON.parse(result.stdout).selected,['main.mbt','src/a.mbt']);
  const version=spawnSync(process.execPath,['cli.mjs','--version'],{cwd:folder,encoding:'utf8'});
  assert.equal(version.status,0); assert.equal(version.stdout,'0.1.0\n');
  console.log('Standalone distribution passed outside the source tree with Node only.');
} finally {
  rmSync(folder,{recursive:true,force:true});
}
