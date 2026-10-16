// Executes the production pure DXF helpers in a small AutoLISP subset.
// This checks data transforms, not AutoCAD rendering or entmod persistence.
import fs from 'node:fs';
import path from 'node:path';
class Sym { constructor(s){this.s=s.toLowerCase();} }
class Pair { constructor(a,d){this.a=a;this.d=d;} }
function parse(s){
 let i=0;
 function ws(){while(i<s.length){if(/\s/.test(s[i]))i++;else if(s[i]===';'){while(i<s.length&&s[i]!=='\n')i++;}else break;}}
 function read(){ws();let c=s[i++];if(c==='('){let a=[];ws();while(s[i]!==')'){if(i>=s.length)throw Error('Unclosed list');if(s[i]==='.'&&/\s/.test(s[i+1])){i++;let d=read();ws();if(s[i++]!==')'||a.length!==1)throw Error('Bad pair');return new Pair(a[0],d);}a.push(read());ws();}i++;return a;}
 if(c==="'")return [new Sym('quote'),read()];
 if(c==='"'){let a='';while(i<s.length){c=s[i++];if(c==='"')return a;if(c==='\\'){c=s[i++];a+=c==='n'?'\n':c==='r'?'\r':c==='t'?'\t':c;}else a+=c;}throw Error('Unclosed string');}
 let a=c;while(i<s.length&&!/[\s()]/.test(s[i]))a+=s[i++];return /^[-+]?\d+(\.\d*)?([eE][-+]?\d+)?$/.test(a)?Number(a):new Sym(a);}
 let out=[];ws();while(i<s.length){out.push(read());ws();}return out;
}
const funcs=new Map();const truth=x=>x!==null&&x!==false&&!(Array.isArray(x)&&x.length===0);
const car=x=>x instanceof Pair?x.a:x?.[0]??null;
const cdr=x=>x instanceof Pair?x.d:Array.isArray(x)?x.slice(1):null;
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const builtins={
 car,cdr,cadr:x=>car(cdr(x)),assoc:(k,a)=>a?.find(p=>same(car(p),k))??null,
 cons:(a,d)=>Array.isArray(d)?[a,...d]:new Pair(a,d),list:(...a)=>a,
 append:(...a)=>a.flat(),reverse:a=>[...a].reverse(),
 '=':(a,b)=>same(a,b),'/=':(a,b)=>!same(a,b),'not':x=>!truth(x),
 '+':(...a)=>a.reduce((x,y)=>x+y,0),'-':(a,b)=>b===undefined?-a:a-b,
 '1+':a=>a+1,'1-':a=>a-1,'<':(a,b)=>a<b,'<=':(a,b)=>a<=b,'>':(a,b)=>a>b,
 strlen:x=>x.length,strcat:(...a)=>a.join(''),strcase:s=>s.toUpperCase(),
 substr:(s,i,n)=>n===undefined?s.slice(i-1):s.slice(i-1,i-1+n),
 'vl-string-search':(needle,s,start=0)=>{let i=s.indexOf(needle,start);return i<0?null:i;},
 member:(x,a)=>{let i=a.findIndex(y=>same(x,y));return i<0?null:a.slice(i);},
 'vl-princ-to-string':s=>String(s),numberp:x=>typeof x==='number',null:x=>!truth(x),
 type:x=>new Sym(typeof x==='string'?'str':typeof x==='number'?'real':'list'),
 'vl-string-translate':(from,to,s)=>[...s].map(c=>from.includes(c)?to[from.indexOf(c)]:c).join(''),
};
function run(x,env={}){
 if(x instanceof Sym)return x.s==='nil'?null:x.s==='t'?true:env[x.s]??null;
 if(!Array.isArray(x))return x;if(!x.length)return null;
 let n=x[0].s,args=x.slice(1);
 if(n==='quote')return args[0];
 if(n==='defun'){funcs.set(args[0].s,{params:args[1],body:args.slice(2)});return null;}
 if(n==='setq'){let v;for(let i=0;i<args.length;i+=2){v=run(args[i+1],env);env[args[i].s]=v;}return v;}
 if(n==='progn'){let v;for(const y of args)v=run(y,env);return v;}
 if(n==='if')return truth(run(args[0],env))?run(args[1],env):args.length>2?run(args[2],env):null;
 if(n==='and'){for(const y of args)if(!truth(run(y,env)))return null;return true;}
 if(n==='or'){for(const y of args){let v=run(y,env);if(truth(v))return v;}return null;}
 if(n==='cond'){for(const branch of args)if(truth(run(branch[0],env)))return run([new Sym('progn'),...branch.slice(1)],env);return null;}
 if(n==='foreach'){for(const y of run(args[1],env)??[]){env[args[0].s]=y;run([new Sym('progn'),...args.slice(2)],env);}return null;}
 if(n==='repeat'){for(let i=0,k=run(args[0],env);i<k;i++)run([new Sym('progn'),...args.slice(1)],env);return null;}
 if(n==='while'){let guard=0;while(truth(run(args[0],env))){if(++guard>10000)throw Error('Loop limit');run([new Sym('progn'),...args.slice(1)],env);}return null;}
 let values=args.map(y=>run(y,env));return call(n,values);
}
function call(n,values){if(builtins[n])return builtins[n](...values);let f=funcs.get(n);if(!f)throw Error('Unsupported function '+n);let env={};let i=0;for(const p of f.params){if(p.s==='/')break;env[p.s]=values[i++];}return run([new Sym('progn'),...f.body],env);}
const repo=path.resolve(import.meta.dirname,'..');
for(const form of parse(fs.readFileSync(path.join(repo,'engine/scripts/replace_frames.lsp'),'utf8')))if(Array.isArray(form)&&form[0]?.s==='defun')run(form);
function dxf(raw){
 let result=[];const re=/\((-?\d+)(?: \. ([\s\S]*?)| ([\d.eE+\- ]+))\)(?= \(|\)$)/g;let m;
 while((m=re.exec(raw))){let code=Number(m[1]);if(m[3]!==undefined){result.push([code,...m[3].trim().split(/ +/).map(Number)]);}else{let value=m[2];if(/^[-+]?\d+(\.\d*)?([eE][-+]?\d+)?$/.test(value))value=Number(value);result.push(new Pair(code,value));}}
 if(!result.some(p=>car(p)===100&&cdr(p)==='AcDbText'))throw Error('Missing text body');return result;
}
function reports(text){let title={},attr=null,result=[];
 for(const line of text.split(/\r?\n/)){
  if(line==='BEGIN_TITLE')title={};else if(line==='BEGIN_ATTRIBUTE')attr={};
  else if(line==='END_ATTRIBUTE'){result.push({...title,...attr});attr=null;}
  else{let i=line.indexOf('=');if(i>=0)(attr??title)[line.slice(0,i)]=line.slice(i+1);}
 }if(!text.includes('AUDIT_COMPLETE=T'))throw Error('Incomplete report');return result;
}
export {reports,dxf,call,car,cdr,same,parse,Pair};
if (path.resolve(process.argv[1])===path.resolve(import.meta.filename)) {
const decoder=new TextDecoder('gb18030');let tested=0;const comparisons=[];
for(const dir of fs.readdirSync(process.argv[2])){
 const folder=path.join(process.argv[2],dir);if(!fs.statSync(folder).isDirectory())continue;
 const files=fs.readdirSync(folder).filter(f=>f.endsWith('_title_geometry_audit.txt'));
 const original=files.find(f=>!f.includes('处理后')),output=files.find(f=>f.includes('处理后'));if(!original||!output)continue;
 const sources=reports(decoder.decode(fs.readFileSync(path.join(folder,original))));
 const targets=reports(decoder.decode(fs.readFileSync(path.join(folder,output))));
 let heights=0,positions=0;
 for(const target of targets){
  // Match per-instance INSERT location/layout and tag; never filename.
  const insert=target.INSERT_DXF.match(/\(10 ([^)]+)\)/)?.[1];
  const matches=sources.filter(s=>s.LAYOUT===target.LAYOUT&&s.TAG===target.TAG&&s.TEXT===target.TEXT&&s.INSERT_DXF.match(/\(10 ([^)]+)\)/)?.[1]===insert);
  if(!matches.length)throw Error(`Missing source ${dir}/${target.TAG}/${insert}`);
  const fields=['HEIGHT','WIDTH_FACTOR','INSERTION_POINT','ALIGNMENT_POINT','HORIZONTAL_MODE','VERTICAL_MODE','ROTATION','TEXT_STYLE'];
  if(matches.some(s=>fields.some(k=>s[k]!==matches[0][k])))throw Error(`Ambiguous geometry ${dir}/${target.TAG}/${insert}`);
  const source=matches[0],src=dxf(source.ATTRIBUTE_DXF),dst=dxf(target.ATTRIBUTE_DXF);
  const value=call('fra:attribute-value',[src]);
  const result=call('fra:preserved-title-data',[dst,src,value]);
  const body=call('fra:attribute-text-body',[result]),expected=call('fra:attribute-text-body',[src]);
  if(!same(body,expected))throw Error('Original text body changed '+dir);
  const originalIdentity=dst.slice(0,dst.findIndex(p=>car(p)===100&&cdr(p)==='AcDbText'));
  if(!same(result.slice(0,originalIdentity.length),originalIdentity))throw Error('Destination identity changed');
  if(source.HEIGHT!==target.HEIGHT)heights++;
  if(source.ALIGNMENT_POINT!==target.ALIGNMENT_POINT)positions++;
  const edited=call('fra:preserved-title-data',[dst,src,'EDITED-123']);
  // User edits must not retain stale text; geometry including MTEXT must survive.
  const geometry=a=>a.filter(p=>![1,3].includes(car(p)));
  if(!same(geometry(call('fra:attribute-text-body',[edited])),geometry(expected)))throw Error('Edited text changes geometry');
  if(!same(cdr(edited.find(p=>car(p)===1)),'EDITED-123'))throw Error('Edited outer text stale');
  // Exercise the actual capture -> writer call path with a stub CAD database.
  // Unexpected fitting/text rewriting fails the test immediately.
  const attrId='destination-attribute';
  const destination=dst.map(p=>car(p)===-1?new Pair(-1,attrId):p);
  const entities=new Map([
   ['source-title',[new Pair(0,'INSERT'),new Pair(66,1)]],['source-attribute',src],
   ['destination-title',[new Pair(0,'INSERT'),new Pair(2,'NEW_TITLE'),new Pair(41,1),new Pair(42,1)]],
   [attrId,destination],['end',[new Pair(0,'SEQEND')]]]);
  const next=new Map([['source-title','source-attribute'],['source-attribute','end'],['destination-title',attrId],[attrId,'end']]);
  builtins.entget=id=>entities.get(id)??null;
  builtins.entnext=id=>next.get(id)??null;
  builtins.entmod=data=>{entities.set(cdr(data.find(p=>car(p)===-1)),data);return data;};
  builtins.entupd=()=>true;
  builtins['fra:fit-overlay-attribute']=()=>{throw Error('Template fitting was used');};
  builtins['fra:fit-drawing-number-attribute']=()=>{throw Error('Drawing number was compressed');};
  builtins['fra:set-attribute-text']=()=>{throw Error('Unedited original rich text was rewritten');};
  builtins.wcmatch=(s,p)=>p==='N*'?s.startsWith('N'):false;
  const values=call('fra:original-title-geometry',[[new Pair(source.TAG,value)],'source-title']);
  call('fra:set-attributes',['destination-title',values]);
  if(!same(call('fra:attribute-text-body',[entities.get(attrId)]),expected))throw Error('Writer altered the captured body');
  tested++;
 }
 comparisons.push({case:dir,matchedAttributes:targets.length,currentHeightDifferences:heights,currentAlignmentDifferences:positions});
}
console.log(JSON.stringify({dataReplay:'PASS',testedAttributes:tested,comparisons,limitation:'Production pure DXF helpers executed; native AutoCAD save/reopen and visual checks still required.'},null,2));
}
