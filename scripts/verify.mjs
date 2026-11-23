import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=dirname(dirname(fileURLToPath(import.meta.url)));
const moon=process.env.MOONPATHSPEC_MOON||(process.env.MOON_HOME?join(process.env.MOON_HOME,'bin',process.platform==='win32'?'moon.exe':'moon'):'moon');
const python=process.env.MOONPATHSPEC_PYTHON||(process.platform==='win32'?'python':'python3');
const version=spawnSync(moon,['version','--all'],{encoding:'utf8',timeout:15000});
const match=version.stdout?.match(/^moonc\s+v?(\d+)\.(\d+)\.(\d+)(?:\+[\w.-]+)?(?=\s|$)/m);
if(version.status!==0||!match||Number(match[1])===0&&(Number(match[2])<10||Number(match[2])===10&&Number(match[3])<22)){
  console.error('A recognized moonc >= 0.10.22 is required. '+(version.error?.message||version.stderr||''));process.exit(2);
}
process.stdout.write(version.stdout);
const steps=[
  [moon,['check','--target','all','--deny-warn']],
  [moon,['test','--target','js','--deny-warn']],
  [moon,['test','--target','wasm-gc','--deny-warn']],
  [moon,['fmt','--check']],
  [moon,['info']],
  [moon,['build','--target','js','--release','--deny-warn']],
  [process.execPath,['--test','tests/integration.mjs']],
  [python,['tests/git_oracle.py','--node',process.execPath,'--git',process.env.MOONPATHSPEC_GIT||'git']],
  [moon,['package']],
  [python,['scripts/check-consumer.py','--moon',moon]],
  [process.execPath,['scripts/package.mjs']],
  [process.execPath,['scripts/check-dist.mjs']],
];
const results=[];
mkdirSync(join(root,'evidence/local'),{recursive:true});
function record(passed,status){
  writeFileSync(join(root,'evidence/local/verification.json'),JSON.stringify({schema_version:1,client_date:process.env.MOONPATHSPEC_VALIDATION_DATE||null,toolchain:version.stdout.trim(),steps:results,passed,status},null,2)+'\n');
}
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
