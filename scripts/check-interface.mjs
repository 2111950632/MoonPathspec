import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const before=readFileSync(process.argv[2],'utf8');
const after=readFileSync(new URL('../pkg.generated.mbti',import.meta.url),'utf8');
// moonc renamed its built-in Int alias to Int32. Ignore that spelling only;
// public declarations, fields and every other type must stay synchronized.
const normalize=text=>text.replace(/\r\n/g,'\n').replace(/\bInt\b/g,'Int32');
assert.equal(normalize(after),normalize(before),'moon info changed the public interface; review and update pkg.generated.mbti');
console.log('Generated public interface is synchronized (Int/Int32 aliases normalized).');
