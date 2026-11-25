#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { invoke } from '../../host.mjs';

const expected = JSON.parse(readFileSync(new URL('./expected.json', import.meta.url), 'utf8'));
let failed = 0;
for (const scenario of expected.cases) {
  try {
    const request = JSON.parse(readFileSync(new URL(scenario.file, import.meta.url), 'utf8'));
    const result = invoke({ ...request, command: 'explain' });
    assert.equal(result.exit_code, 0, JSON.stringify(result.error));
    assert.deepEqual(result.selected, scenario.selected, scenario.file);
    process.stdout.write('PASS ' + scenario.file + ': ' + scenario.name + '\n');
    process.stdout.write('  selected=' + JSON.stringify(result.selected) + '\n');
    for (const path of scenario.explain_paths) {
      const decision = result.decisions.find(item => item.path === path);
      assert.ok(decision, 'Missing explanation for ' + path);
      process.stdout.write('  ' + (decision.selected ? '+' : '-') + ' ' + JSON.stringify(path) +
        ': ' + decision.reason + '; include=' + decision.included_by.join(',') +
        ' exclude=' + decision.excluded_by.join(',') + '\n');
    }
  } catch (error) {
    failed += 1;
    process.stderr.write('FAIL ' + scenario.file + ': ' + error.message + '\n');
  }
}
process.stdout.write('Fixed-expectation scenarios: ' + (expected.cases.length - failed) +
  '/' + expected.cases.length + ' passed. See expected.json for independent Git measurement limits.\n');
if (failed) process.exitCode = 1;
