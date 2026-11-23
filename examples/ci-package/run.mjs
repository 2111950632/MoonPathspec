#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { invoke } from '../../host.mjs';

// The caller supplies paths and attribute values. Selection and explanations
// come from the compiled MoonBit core; this host never interprets a pattern.
const cases = JSON.parse(readFileSync(new URL('./expected.json', import.meta.url), 'utf8'));
try {
  for (const scenario of cases) {
    const request = JSON.parse(readFileSync(new URL(scenario.file, import.meta.url), 'utf8'));
    const result = invoke({ ...request, command: 'explain' });
    assert.equal(result.exit_code, 0, JSON.stringify(result.error));
    assert.deepEqual(result.selected, scenario.selected, scenario.file);
    for (const expected of scenario.decisions) {
      const actual = result.decisions.find(item => item.path === expected.path);
      assert.ok(actual, `Missing explanation for ${expected.path}`);
      for (const key of ['selected', 'included_by', 'excluded_by', 'reason']) {
        assert.deepEqual(actual[key], expected[key], `${scenario.file}: ${expected.path} ${key}`);
      }
    }
    process.stdout.write(`PASS ${scenario.file}: ${scenario.name}\n`);
    process.stdout.write(`  selected=${JSON.stringify(result.selected)}\n`);
    for (const decision of result.decisions) {
      process.stdout.write(`  ${decision.selected ? '+' : '-'} ${JSON.stringify(decision.path)}: ${decision.reason}; include=${decision.included_by.join(',')} exclude=${decision.excluded_by.join(',')}\n`);
    }
  }
  process.stdout.write(`Verified ${cases.length} scenarios against handwritten expected results.\n`);
} catch (error) {
  process.stderr.write(`CI package example failed: ${error.message}\n`);
  process.exitCode = 1;
}
