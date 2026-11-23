import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, rmSync, readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const root=dirname(dirname(fileURLToPath(import.meta.url)));
const distribution=join(root,'dist');
const manifest=JSON.parse(readFileSync(join(distribution,'manifest.json'),'utf8'));
assert.equal(manifest.schema_version,1);
assert.deepEqual(readdirSync(distribution).sort(),[...Object.keys(manifest.files),'manifest.json'].sort());
for (const [name, expected] of Object.entries(manifest.files)) {
  assert.match(name,/^[A-Za-z0-9_.-]+$/, 'Distribution paths must be basenames');
  const bytes=readFileSync(join(distribution,name));
  assert.equal(bytes.length,expected.bytes,name+' size');
  assert.equal(createHash('sha256').update(bytes).digest('hex'),expected.sha256,name+' checksum');
}
const folder=mkdtempSync(join(tmpdir(),'moonpathspec-dist-'));
try {
  cpSync(join(root,'dist'),folder,{recursive:true});
  const request={patterns:[':(glob)**/*.mbt',':(exclude)vendor'],paths:['main.mbt','src/a.mbt','vendor/a.mbt','README.md']};
  const result=spawnSync(process.execPath,['cli.mjs','--input','-','--json'],{cwd:folder,input:JSON.stringify(request),encoding:'utf8',timeout:30000});
  assert.equal(result.status,0,result.stderr);
  assert.deepEqual(JSON.parse(result.stdout).selected,['main.mbt','src/a.mbt']);
  const version=spawnSync(process.execPath,['cli.mjs','--version'],{cwd:folder,encoding:'utf8'});
  assert.equal(version.status,0); assert.equal(version.stdout,manifest.version+'\n');
  console.log('Distribution inventory and checksums verified; standalone CLI passed outside the source tree with Node only.');
} finally {
  rmSync(folder,{recursive:true,force:true});
}
