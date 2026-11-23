import { mkdirSync, readFileSync, writeFileSync, existsSync, lstatSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const output = resolve(root, 'dist');
// Only this generated directory may be cleaned; never follow a redirected dist.
if (dirname(output) !== resolve(root) || output !== join(resolve(root), 'dist')) throw new Error('Unexpected distribution path');
if (existsSync(output) && lstatSync(output).isSymbolicLink()) throw new Error('Refusing a symlinked distribution directory');
// Read all required inputs before replacing the previous successful package.
const sources = new Map([
  ['moonpathspec-core.js', readFileSync(join(root, '_build/js/release/build/cmd/bridge/bridge.js'))],
  ...['LICENSE','NOTICE','THIRD_PARTY.md','host.mjs','io.mjs','cli.mjs'].map(name => [name, readFileSync(join(root,name))]),
]);
const metadata = JSON.parse(readFileSync(join(root,'package.json'),'utf8'));
rmSync(output, { recursive: true, force: true });
mkdirSync(output);
const files = {};
for (const [name, bytes] of sources) {
  writeFileSync(join(output, name), bytes);
  files[name] = { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
}
writeFileSync(join(output,'manifest.json'),JSON.stringify({schema_version:1,version:metadata.version,core:'moonpathspec-core.js',host:'host.mjs',cli:'cli.mjs',license:'Apache-2.0',files},null,2)+'\n');
console.log('Packaged standalone Node CLI, compiled MoonBit core and license notices in dist/.');
