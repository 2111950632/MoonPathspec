import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { invoke } from '../host.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const variableNames = ['GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS'];
function cli(args, request, values = {}) {
  const env = { ...process.env };
  for (const name of variableNames) delete env[name];
  Object.assign(env, values);
  const command = ['inspect', 'select', 'explain'].includes(args[0]) ? args[0] : undefined;
  const flags = command ? args.slice(1) : args;
  const result = spawnSync(process.execPath, ['cli.mjs', ...(command ? [command] : []), '--json', '--input', '-', ...flags], {
    cwd: root, env, input: JSON.stringify(request), encoding: 'utf8', timeout: 30000,
  });
  assert.equal(result.signal, null);
  return { ...result, data: JSON.parse(result.stdout) };
}
const request = { patterns: ['*.txt'], paths: ['a.txt', 'sub/b.txt'] };

test('global CLI modes and per-pattern overrides preserve Git distinctions', () => {
  assert.deepEqual(cli(['--glob-pathspecs'], request).data.selected, ['a.txt']);
  assert.deepEqual(cli(['--noglob-pathspecs'], request).data.selected, []);
  assert.deepEqual(cli(['--noglob-pathspecs'], { ...request, patterns: [':(glob)*.txt'] }).data.selected, ['a.txt']);
  assert.deepEqual(cli(['--glob-pathspecs'], { patterns: [':(literal)*.txt'], paths: ['*.txt', 'a.txt'] }).data.selected, ['*.txt']);
});

test('global literal mode suppresses magic parsing and no form re-enables it', () => {
  const value = { patterns: [':(glob)a*'], paths: [':(glob)a*', 'abc'] };
  assert.deepEqual(cli(['--literal-pathspecs'], value).data.selected, [':(glob)a*']);
  assert.deepEqual(cli(['--literal-pathspecs', '--no-literal-pathspecs'], value).data.selected, ['abc']);
  assert.deepEqual(cli(['--icase-pathspecs'], { patterns: ['A.TXT'], paths: ['a.txt'] }).data.selected, ['a.txt']);
  assert.deepEqual(cli(['--icase-pathspecs', '--no-icase-pathspecs'], { patterns: ['A.TXT'], paths: ['a.txt'] }).data.selected, []);
});

test('CLI flags override JSON options which override raw process environment', () => {
  const input = { ...request, options: { glob: false } };
  const env = { GIT_GLOB_PATHSPECS: 'yes' };
  assert.deepEqual(cli([], request, env).data.selected, ['a.txt']);
  assert.deepEqual(cli([], input, env).data.selected, request.paths);
  assert.deepEqual(cli(['--glob-pathspecs'], input, env).data.selected, ['a.txt']);
  assert.deepEqual(cli(['--no-glob-pathspecs'], request, env).data.selected, request.paths);
  assert.deepEqual(cli(['--glob-pathspecs', '--no-glob-pathspecs'], request).data.selected, request.paths);
});

test('invalid raw environment fails in MoonBit and explicit override recovers', () => {
  const invalid = { GIT_GLOB_PATHSPECS: 'not-a-bool' };
  const failure = cli([], request, invalid);
  assert.equal(failure.status, 2);
  assert.equal(failure.data.error.code, 'invalid_request');
  assert.deepEqual(failure.data.selected, []);
  assert.deepEqual(cli(['--no-glob-pathspecs'], request, invalid).data.selected, request.paths);
  assert.deepEqual(cli([], { ...request, options: { glob: false } }, invalid).data.selected, request.paths);
});

test('global conflicts and malformed options return structured errors', () => {
  for (const options of [{ glob: true, noglob: true }, { literal: true, icase: true }, { glob: 1 }, { typo: false }]) {
    const result = invoke({ patterns: [], paths: [], options });
    assert.equal(result.exit_code, 2);
    assert.deepEqual(result.selected, []);
  }
  assert.equal(cli(['--glob-pathspecs', '--noglob-pathspecs'], request).status, 2);
  assert.equal(cli(['--path-mode', 'invalid'], request).status, 2);
});

test('inspect reports explicit path preprocessing and byte-prefix metadata', () => {
  const input = { patterns: [':(prefix:4,icase)src/A'] };
  const normal = cli(['inspect'], input);
  assert.equal(normal.status, 0);
  assert.equal(normal.data.options.windows, false);
  assert.equal(normal.data.patterns[0].prefix_length, 4);
  assert.equal(cli(['inspect', '--path-mode', 'windows'], input).data.options.windows, true);
  assert.equal(cli(['inspect', '--path-mode', 'posix'], { ...input, options: { windows: true } }).data.options.windows, false);
});

test('Linux and Windows reference modes retain measured binary environment behavior', () => {
  const input = { patterns: [':(top)A.TXT'], paths: ['a.txt'] };
  const values = { GIT_ICASE_PATHSPECS: '0b1' };
  assert.deepEqual(cli(['--path-mode', 'posix'], input, values).data.selected, ['a.txt']);
  const windows = cli(['--path-mode', 'windows'], input, values);
  assert.equal(windows.status, 2);
  assert.equal(windows.data.error.code, 'invalid_request');
  assert.deepEqual(windows.data.selected, []);
});

test('explicit Git reference version keeps independently measured signed limits', () => {
  const input = { patterns: ['A'], paths: ['a'] };
  const values = { GIT_ICASE_PATHSPECS: '-2g' };
  assert.deepEqual(cli(['--git-version', '2.56.0'], input, values).data.selected, ['a']);
  const legacy = cli(['--git-version', '2.43.0'], input, values);
  assert.equal(legacy.status, 2);
  assert.equal(legacy.data.error.code, 'invalid_request');
  const inspected = cli(['inspect', '--git-version', '2.43.0'], { patterns: ['*'] });
  assert.equal(inspected.data.options.git_version, '2.43.0');
  assert.equal(cli(['--git-version', 'unknown'], input).status, 2);
});
