import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=dirname(dirname(fileURLToPath(import.meta.url)));
const groups={production:[],tests:[]};
function walk(dir){for(const item of readdirSync(dir,{withFileTypes:true})){
  if(['.git','_build','.mooncakes','node_modules','dist','evidence'].includes(item.name))continue;
  const path=join(dir,item.name);
  if(item.isDirectory())walk(path);
  else if(item.name.endsWith('.mbt')){
    const lines=readFileSync(path,'utf8').split(/\r?\n/); if(lines.at(-1)==='')lines.pop();
    groups[/(?:_test|_wbtest)\.mbt$/.test(item.name)?'tests':'production'].push({file:relative(root,path).replaceAll('\\','/'),total:lines.length,nonblank_noncomment:lines.filter(x=>x.trim()&&!x.trimStart().startsWith('//')).length});
  }
}}
walk(root);
const totals=Object.fromEntries(Object.entries(groups).map(([k,v])=>[k,{files:v.length,total:v.reduce((n,f)=>n+f.total,0),nonblank_noncomment:v.reduce((n,f)=>n+f.nonblank_noncomment,0)}]));
console.log(JSON.stringify({method:'Nonblank lines excluding whole-line // comments; structural syntax included. Tests and host code separate; not organizer-certified effective LOC.',totals,files:groups},null,2));
