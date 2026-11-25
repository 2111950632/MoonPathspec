import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { invoke } from '../host.mjs';
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const version = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).version;
function cli(args, input) { return spawnSync(process.execPath, ['cli.mjs', ...args], { cwd: root, input, encoding: 'utf8', timeout: 30000 }); }
function json(args, input) {
  const separator = args.indexOf('--');
  const marked = [...args]; marked.splice(separator < 0 ? marked.length : separator, 0, '--json');
  const r = cli(marked, input); return { ...r, data: JSON.parse(r.stdout) };
}
function temporary(action) {
  const dir = mkdtempSync(join(tmpdir(), 'moonpathspec-cli-'));
  try { action(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}
test('build/file selection example has deterministic JSON', () => {
  const r = json(['--input', 'examples/files.json']);
  assert.equal(r.status, 0); assert.equal(r.data.schema_version, 1);
  assert.deepEqual(r.data.selected, ['main.mbt', 'src/parser.mbt']);
});
test('attribute fixture requires both set and unset conditions', () => {
  const r = json(['--input', 'examples/attributes.json']);
  assert.equal(r.status, 0); assert.deepEqual(r.data.selected, ['src/hand.mbt']);
});
test('literal fixture preserves bracket filename and prefix', () => {
  assert.deepEqual(json(['--input','examples/literal.json']).data.selected, ['src/a[1].mbt']);
});
test('explanation identifies the selecting and excluding rule indices', () => {
  const r = cli(['explain','--input','examples/files.json']);
  assert.equal(r.status, 0); assert.match(r.stdout, /vendor\/code\.mbt.*excluded_by_pattern; include=0 exclude=1/);
});
test('inspect exposes compiled rule properties without needing paths', () => {
  const r = json(['inspect','--prefix','src','--',':(top,icase,glob)**/*.md']);
  assert.equal(r.status, 0); assert.equal(r.data.patterns[0].top, true);
  assert.equal(r.data.patterns[0].anchor, '');
});
test('default wildcard crosses slash, glob wildcard does not', () => {
  const args = ['--path','doc/a.jpg','--path','doc/sub/b.jpg','--'];
  assert.deepEqual(json([...args,'doc/*.jpg']).data.selected,['doc/a.jpg','doc/sub/b.jpg']);
  assert.deepEqual(json([...args,':(glob)doc/*.jpg']).data.selected,['doc/a.jpg']);
});
test('CRLF path input and NUL output are host I/O only', () => temporary(dir => {
  const path = join(dir,'list'); writeFileSync(path,'a.mbt\r\nb.txt\r\n');
  const r = cli(['--paths',path,'--null','--','*.mbt']);
  assert.equal(r.status,0); assert.equal(r.stdout,'a.mbt\0');
}));
test('NUL-delimited input preserves filenames with a newline', () => temporary(dir => {
  const path = join(dir,'list'); writeFileSync(path,'a\nb.mbt\0c.txt\0');
  const r = json(['--paths',path,'--null-input','--','*.mbt']);
  assert.equal(r.status,0); assert.deepEqual(r.data.selected,['a\nb.mbt']);
}));
test('missing and malformed files fail with exit 2', () => temporary(dir => {
  assert.equal(cli(['--input',join(dir,'absent')]).status,2);
  const path=join(dir,'bad.json'); writeFileSync(path,'{');
  assert.equal(json(['--input',path]).status,2);
}));
test('raw invalid UTF-8 is rejected before decoding to a replacement character', () => temporary(dir => {
  const path=join(dir,'bad-paths'); writeFileSync(path,Buffer.from([0xff,0x0a]));
  const r=json(['--paths',path]); assert.equal(r.status,2); assert.equal(r.data.error.code,'host_error');
}));
test('argument errors and competing stdin readers fail clearly', () => {
  for(const args of [['--prefix'],['--unknown'],['--input','-','--paths','-']]) assert.equal(cli(args,'{}').status,2);
});
test('unknown core fields and attribute value types are rejected', () => {
  for(const data of [{patterns:[],paths:[],typo:true},{patterns:[],paths:['a'],attributes:{a:{bad:42}}}]) {
    const r=json(['--input','-'],JSON.stringify(data)); assert.equal(r.status,2); assert.equal(r.data.error.code,'invalid_request');
  }
});
test('budget failure has no partial selected file list', () => {
  const r=invoke({patterns:['*'],paths:['abc'],limits:{max_match_steps:1}});
  assert.equal(r.exit_code,2); assert.deepEqual(r.selected,[]);
});
test('Unicode question marks count UTF-8 bytes', () => {
  assert.deepEqual(invoke({patterns:['u/?.txt'],paths:['u/猫.txt']}).selected,[]);
  assert.deepEqual(invoke({patterns:['u/???.txt'],paths:['u/猫.txt']}).selected,['u/猫.txt']);
});
test('batch runner bridges multiple requests independently', () => {
  const r=spawnSync(process.execPath,['scripts/request.mjs'],{cwd:root,input:JSON.stringify({batch:[{patterns:['a'],paths:['a','b']},{patterns:['b'],paths:['a','b']}]}),encoding:'utf8'});
  assert.equal(r.status,0); assert.deepEqual(JSON.parse(r.stdout).results.map(x=>x.selected),[['a'],['b']]);
});
test('escaped star selects a literal special character', () => {
  const r=invoke({patterns:['a\\*'],paths:['a*','abc']}); assert.equal(r.exit_code,0); assert.deepEqual(r.selected,['a*']);
});
test('invalid duplicate paths and invalid limits fail', () => {
  assert.equal(invoke({patterns:[],paths:['a','a']}).error.code,'duplicate_path');
  assert.equal(invoke({patterns:[],paths:[],limits:{max_paths:0}}).error.code,'invalid_limits');
  assert.equal(invoke({patterns:[],paths:[],limits:{max_paths:1.5}}).error.code,'invalid_request');
});
test('help, version and empty file sets work without silent failures', () => {
  assert.equal(cli(['--version']).stdout,version+'\n'); assert.match(cli(['--help']).stdout,/Usage:/);
  const r=json([]); assert.equal(r.status,0); assert.deepEqual(r.data.selected,[]);
});
test('option-like filenames after the separator remain patterns', () => {
  for (const name of ['--help', '--version', '--json']) {
    const r=cli(['--path',name,'--',name]); assert.equal(r.status,0); assert.equal(r.stdout,name+'\n');
  }
});
