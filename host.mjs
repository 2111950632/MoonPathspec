import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
const root = dirname(fileURLToPath(import.meta.url));
let script;
export function invoke(request) {
  if (!script) {
    const paths = ['_build/js/release/build/cmd/bridge/bridge.js', 'dist/moonpathspec-core.js', 'moonpathspec-core.js'];
    const path = paths.map(p => join(root, p)).find(existsSync);
    if (!path) throw new Error('Build first: moon build --target js --release');
    script = new vm.Script(readFileSync(path, 'utf8'), { filename: 'moonpathspec-core.js' });
  }
  const context = vm.createContext({ __moonpathspecRequest: JSON.stringify(request), console, TextEncoder, TextDecoder });
  script.runInContext(context, { timeout: 30000 });
  if (typeof context.__moonpathspecResponse !== 'string') throw new Error('Missing core response');
  return JSON.parse(context.__moonpathspecResponse);
}
