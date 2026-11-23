import { readFileSync } from 'node:fs';
import { invoke } from '../host.mjs';
try {
  const input = readFileSync(0);
  if (input.length > 16777216) throw new Error('Input exceeds 16 MiB');
  const request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(input));
  process.stdout.write(JSON.stringify(invoke(request)) + '\n');
} catch (error) {
  process.stdout.write(JSON.stringify({ schema_version: 1, exit_code: 2, selected: [], error: { code: 'host_error', message: error.message } }) + '\n');
  process.exitCode = 2;
}
