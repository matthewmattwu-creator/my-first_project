import fs from 'node:fs';
import path from 'node:path';
import {call,parse,Pair,same} from './title_geometry_replay.mjs';
let checked=0;
function check(condition,label){if(!condition)throw Error(label);console.log('PASS '+label);checked++;}
const p=(code,value)=>new Pair(code,value);
for(const [sx,sy,rot] of [[150.00001811,150.00001811,0],[49.99995061,49.99995061,0],[-2.25,3.125,Math.PI/3]]) {
 const point=[123.123456789,456.987654321,0];
 const data=[p(0,'INSERT'),[10,...point],p(41,sx),p(42,sy),p(50,rot)];
 const result=call('fra:original-title-transform',[data,[0,0,0],150,150,0]);
 check(same(result,[point,sx,sy,rot]),'original point, scales and rotation preserved '+sx+'/'+sy);
}
check(same(call('fra:original-title-transform',[[p(0,'INSERT'),[10,1,2,0]],[0,0,0],150,150,1]),[[1,2,0],1,1,0]),'native INSERT defaults do not inherit frame scale');
check(same(call('fra:original-title-transform',[null,[8,9,0],2,3,0.5]),[[8,9,0],2,3,0.5]),'missing native title keeps explicit existing fallback');
check(same(call('fra:original-title-transform',[[p(41,50),p(42,50)],[0,0,0],150,150,0]).slice(1),[50,50,0]),'different next sheet has independent values');
const source=fs.readFileSync(path.resolve(import.meta.dirname,'../engine/scripts/replace_frames.lsp'),'utf8');
const forms=parse(source),calls=[];
function visit(x){if(Array.isArray(x)){if(x[0]?.s)calls.push(x);for(const item of x)visit(item);}}
forms.forEach(visit);
const symbols=x=>x.map(v=>v?.s??v);
const inserts=calls.filter(x=>x[0]?.s==='fra:insert');
check(inserts.some(x=>same(symbols(x),['fra:insert','title-library','title-name','title-point','title-sx','title-sy','title-rotation'])),'new title insert consumes original title transform');
check(inserts.some(x=>same(symbols(x),['fra:insert','border-library','border-name','point','sx','sy','rotation'])),'frame insert retains original frame transform');
check(!inserts.some(x=>x[1]?.s==='title-library'&&x[4]?.s==='sx'),'native title does not consume frame X scale');
check(calls.some(x=>same(symbols(x),['fra:insert-signatures','new-title','values','title-sx','title-sy','title-rotation'])),'new signatures use title transform');
console.log('ALL '+checked+' TITLE TRANSFORM CHECKS PASSED; data and source call checks only, no native CAD writes.');
