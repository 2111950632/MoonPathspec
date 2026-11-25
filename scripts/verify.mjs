import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=dirname(dirname(fileURLToPath(import.meta.url)));
const moon=process.env.MOONPATHSPEC_MOON||(process.env.MOON_HOME?join(process.env.MOON_HOME,'bin',process.platform==='win32'?'moon.exe':'moon'):'moon');
const python=process.env.MOONPATHSPEC_PYTHON||(process.platform==='win32'?'python':'python3');
const results=[];
const runId=randomUUID(), startedAt=new Date().toISOString();
let toolchain='';
mkdirSync(join(root,'evidence/local'),{recursive:true});
function record(passed,status){
  writeFileSync(join(root,'evidence/local/verification.json'),JSON.stringify({schema_version:1,run_id:runId,started_at:startedAt,updated_at:new Date().toISOString(),client_date:process.env.MOONPATHSPEC_VALIDATION_DATE||null,toolchain,steps:results,passed,status},null,2)+'\n');
}
// Invalidate yesterday's successful evidence before any tool can fail today.
record(false,'running');
const version=spawnSync(moon,['version','--all'],{encoding:'utf8',timeout:15000});
toolchain=version.stdout?.trim()||'';
const match=version.stdout?.match(/^moonc\s+v?(\d+)\.(\d+)\.(\d+)(?:\+[\w.-]+)?(?=\s|$)/m);
if(version.status!==0||!match||Number(match[1])===0&&(Number(match[2])<10||Number(match[2])===10&&Number(match[3])<22)){
  results.push({step:'toolchain version',exit_code:2,error:version.error?.message||version.stderr||'Unrecognized or unsupported compiler version'});
  record(false,'failed');
  console.error('A recognized moonc >= 0.10.22 is required. '+(version.error?.message||version.stderr||''));process.exit(2);
}
process.stdout.write(version.stdout);
const interfaceBaseline=join(root,'evidence/local/interface-before.mbti');
try { writeFileSync(interfaceBaseline,readFileSync(join(root,'pkg.generated.mbti'))); }
catch(error) { results.push({step:'read interface baseline',exit_code:2,error:error.message});record(false,'failed');process.exit(2); }
const steps=[
  [process.execPath,['scripts/check-release.mjs']],
  [moon,['check','--target','all','--deny-warn']],
  [moon,['test','--target','js','--deny-warn']],
  [moon,['test','--target','wasm-gc','--deny-warn']],
  [moon,['fmt','--check']],
  [moon,['info']],
  [process.execPath,['scripts/check-interface.mjs',interfaceBaseline]],
  [moon,['build','--target','js','--release','--deny-warn']],
  [process.execPath,['--test','tests/integration.mjs','tests/host_io.mjs','tests/scenarios.mjs','tests/pathspec_options.mjs','tests/distribution.mjs','tests/verification.mjs']],
  [python,['tests/git_oracle.py','--node',process.execPath,'--git',process.env.MOONPATHSPEC_GIT||'git']],
  [python,['tests/escaped_oracle.py','--node',process.execPath,'--git',process.env.MOONPATHSPEC_GIT||'git']],
  [process.execPath,['examples/escaped-pathspec/run.mjs']],
  [moon,['package']],
  [python,['scripts/check-consumer.py','--moon',moon]],
  [process.execPath,['scripts/package.mjs']],
  [process.execPath,['scripts/check-dist.mjs']],
];
record(false,'running');
for(const [program,args] of steps){
  console.log('\nVerifying: '+args.join(' '));
  const result=spawnSync(program,args,{cwd:root,stdio:'inherit',timeout:300000});
  results.push({step:args.join(' '),exit_code:result.status});
  if(result.error||result.status!==0){record(false,'failed');console.error(result.error?.message||'Stopped at a failing verification step.');process.exit(result.status||2);}
  record(false,'running');
}
record(true,'passed');
console.log('\nAll verification steps passed.');
