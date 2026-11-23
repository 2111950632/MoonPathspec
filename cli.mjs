#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { invoke } from './host.mjs';

const help = `MoonPathspec 0.1.0
Usage: node cli.mjs [select|explain|inspect] [options] -- PATTERN...
  --input FILE       JSON request manifest (use - for stdin)
  --paths FILE       UTF-8 file of candidate paths, one per line
  --null-input       Read --paths as NUL-delimited paths
  --path PATH        Add a candidate path (repeatable)
  --prefix DIR       Repository-relative caller directory
  --attributes FILE  JSON path-to-attributes object
  --limits FILE      JSON limits object
  --json             Print the versioned JSON response
  --null             Print selected paths separated by NUL
  --help, --version
Patterns and all selection semantics are evaluated by the MoonBit core.
No patterns means the caller prefix's file set. Exit: 0 success, 2 error.
`;

function readText(path) {
  const bytes = readFileSync(path === '-' ? 0 : path);
  if (bytes.length > 16777216) throw new Error('File exceeds 16 MiB');
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}

let json = false;
try {
  const args = process.argv.slice(2);
  let command = 'select', input, pathsFile, attrsFile, limitsFile, prefix;
  let nul = false, nulInput = false;
  const paths = [], patterns = [];
  if (['select', 'explain', 'inspect'].includes(args[0])) command = args.shift();
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--') { patterns.push(...args.slice(i + 1)); break; }
    if (arg === '--help') { process.stdout.write(help); process.exit(0); }
    if (arg === '--version') { process.stdout.write('0.1.0\n'); process.exit(0); }
    if (['--input','--paths','--attributes','--limits','--prefix','--path'].includes(arg)) {
      if (i + 1 >= args.length) throw new Error(`Missing value for ${arg}`);
      const value = args[++i];
      if (arg === '--input') input = value;
      else if (arg === '--paths') pathsFile = value;
      else if (arg === '--attributes') attrsFile = value;
      else if (arg === '--limits') limitsFile = value;
      else if (arg === '--prefix') prefix = value;
      else paths.push(value);
    } else if (arg === '--json') json = true;
    else if (arg === '--null') nul = true;
    else if (arg === '--null-input') nulInput = true;
    else if (arg.startsWith('--')) throw new Error(`Unknown option ${arg}; pass patterns after --`);
    else patterns.push(arg);
  }
  if ([input, pathsFile, attrsFile, limitsFile].filter(x => x === '-').length > 1) throw new Error('stdin may only be read once');
  const request = input ? JSON.parse(readText(input)) : { patterns: [], paths: [] };
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw new Error('Input must be a JSON request object');
  request.command = command;
  if (patterns.length) request.patterns = patterns;
  if (pathsFile) {
    const text = readText(pathsFile);
    const lines = text.split(nulInput ? '\0' : /\r?\n/);
    if (lines.at(-1) === '') lines.pop();
    request.paths = lines;
  }
  if (paths.length) {
    if (!Array.isArray(request.paths)) request.paths = paths;
    else request.paths = [...request.paths, ...paths];
  }
  if (prefix !== undefined) request.prefix = prefix;
  if (attrsFile) request.attributes = JSON.parse(readText(attrsFile));
  if (limitsFile) request.limits = JSON.parse(readText(limitsFile));
  const response = invoke(request);
  if (json || command === 'inspect') process.stdout.write(JSON.stringify(response, null, 2) + '\n');
  else if (response.exit_code !== 0) process.stderr.write(`${response.error.code}: ${response.error.message}\n`);
  else if (command === 'explain') {
    for (const d of response.decisions) process.stdout.write(`${d.selected ? '+' : '-'} ${JSON.stringify(d.path)}: ${d.reason}; include=${d.included_by.join(',')} exclude=${d.excluded_by.join(',')}\n`);
  } else {
    const separator = nul ? '\0' : '\n';
    if (response.selected.length) process.stdout.write(response.selected.join(separator) + separator);
  }
  process.exitCode = response.exit_code;
} catch (error) {
  if (json) process.stdout.write(JSON.stringify({ schema_version: 1, exit_code: 2, selected: [], error: { code: 'host_error', message: error.message } }) + '\n');
  else process.stderr.write(`moonpathspec: ${error.message}\n`);
  process.exitCode = 2;
}
