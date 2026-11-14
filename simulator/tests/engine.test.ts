import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGame, resolveRound, resolveRevealTimeout, combatSurvivors, assertState, legalOrders, HOLD, invalidReason } from '../src/engine/game.ts';
import type { Side, Order } from '../src/engine/game.ts';
import { scenarioState, parseReplay, replayTimeline } from '../src/engine/replay.ts';
import { suggestOrder } from '../src/engine/bot.ts';
const move=(destination:number):Order=>({action:'Move',destination});
const capture:Order={action:'Capture',destination:255};const build:Order={action:'Build',destination:0};
test('real path: move, capture, leave, persistent income',()=>{
 let s=createGame();s=resolveRound(s,move(1)).state;assert.equal(s.players.A.energy,6);s=resolveRound(s,move(2)).state;assert.equal(s.players.A.energy,7);
 s=resolveRound(s,capture).state;assert.equal(s.players.A.energy,10);assert.equal(s.owners[2],'A');s=resolveRound(s,move(3)).state;assert.equal(s.players.A.energy,12);assert.equal(s.players.A.points,2);
});
test('resolution never mutates its input',()=>{const s=createGame();const before=structuredClone(s);resolveRound(s,move(1));assert.deepEqual(s,before);});
test('400 combat combinations preserve simultaneous damage',()=>{
 for(let a=1;a<=10;a++)for(let b=1;b<=10;b++)for(const da of [false,true])for(const db of [false,true]){const [ra,rb]=combatSurvivors(a,b,da,db);assert.equal(a-ra,Math.min(a,b+Number(db)));assert.equal(b-rb,Math.min(b,a+Number(da)));assert.ok(!ra||!rb);}
});
test('swap survivor stays at origin; both pay',()=>{
 const r=resolveRound(scenarioState('combat'),move(2),move(1)).state;assert.equal(r.players.A.position,1);assert.equal(r.players.A.ships,2);assert.equal(r.players.B.ships,0);assert.equal(r.players.B.position,24);assert.equal(r.players.A.energy,6);assert.equal(r.players.B.energy,6);
});
test('defense increases damage; dead fleet cannot capture',()=>{
 const s=scenarioState('defense');const r=resolveRound(s,move(2),{action:'Defend',destination:0}).state;assert.equal(r.players.A.ships,0);assert.equal(r.players.B.ships,0);
 const c=resolveRound(s,move(2),capture).state;assert.equal(c.owners[2],null);assert.equal(c.players.A.ships,1);
});
test('winning a combat does not transfer territory',()=>{
 const s=scenarioState('combat');s.owners[2]='B';const r=resolveRound(s,move(2)).state;assert.equal(r.owners[2],'B');assert.equal(r.players.B.points,1);
});
test('illegal orders become hold without charging',()=>{
 for(const d of [0,2,6,25]){const r=resolveRound(createGame(),move(d)).state;assert.equal(r.players.A.position,0);assert.equal(r.players.A.energy,7);}
 const s=createGame();s.players.A.position=4;assert.ok(invalidReason(s,'A',move(5)));
});
test('rebuild, cap and affordability before income',()=>{
 const r=resolveRound(scenarioState('rebuild'),build,build).state;assert.equal(r.players.A.ships,1);assert.equal(r.players.A.energy,4);
 const poor=createGame();poor.players.A.energy=2;poor.players.B.ships=10;const no=resolveRound(poor,build,build).state;assert.equal(no.players.A.ships,3);assert.equal(no.players.A.energy,4);assert.equal(no.players.B.ships,10);
});
test('tiebreak excludes core',()=>{
 const s=createGame();s.round=10;s.owners[12]='A';s.owners[2]='B';s.players.B.points=2;const r=resolveRound(s).state;assert.equal(r.players.A.points,r.players.B.points);assert.equal(r.result,'PlayerBWins');
});
test('ten rounds complete once',()=>{
 let s=createGame();for(let i=0;i<10;i++)s=resolveRound(s).state;assert.equal(s.round,10);assert.equal(s.result,'Draw');assert.equal(s.players.A.energy,25);assert.throws(()=>resolveRound(s));
});
test('second reveal fault ends before execution or income',()=>{
 let s=createGame();s=resolveRevealTimeout(s,{A:true,B:true},{A:HOLD}).state;assert.equal(s.players.B.faults,1);assert.equal(s.round,2);
 s=resolveRevealTimeout(s,{A:true,B:true},{A:move(1)}).state;assert.equal(s.result,'PlayerAWins');assert.equal(s.players.A.position,0);assert.equal(s.players.A.energy,7);
});
test('both second faults draw; no commitment means no reveal fault',()=>{
 let s=createGame();s=resolveRevealTimeout(s,{A:false,B:false},{}).state;assert.equal(s.players.A.faults,0);s=resolveRevealTimeout(s,{A:true,B:true},{}).state;s=resolveRevealTimeout(s,{A:true,B:true},{}).state;assert.equal(s.result,'Draw');
});
test('imports recalculate state and reject malformed replays',()=>{
 const r=parseReplay(JSON.stringify({version:1,scenario:'standard',turns:[{A:move(1),B:HOLD}]}));assert.equal(replayTimeline(r).states[1].players.A.position,1);
 assert.throws(()=>parseReplay('{'));assert.throws(()=>parseReplay('{"version":1,"scenario":"__proto__","turns":[]}'));assert.throws(()=>parseReplay(JSON.stringify({version:1,scenario:'standard',turns:Array(11).fill({A:HOLD,B:HOLD})})));
});
test('100 generated games preserve invariants for 1000 rounds',()=>{
 let seed=42;const random=(n:number)=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
 for(let match=0;match<100;match++){let s=createGame();for(let r=0;r<10;r++){const pick=(side:Side)=>{const options=legalOrders(s,side);return options[random(options.length)];};s=resolveRound(s,pick('A'),pick('B')).state;assertState(s);}assert.equal(s.status,'Finished');}
});
test('bot chooses legal orders through a full demo',()=>{
 let s=createGame();for(let r=0;r<10;r++){const a=suggestOrder(s,'A'),b=suggestOrder(s,'B');assert.equal(invalidReason(s,'A',a),null);assert.equal(invalidReason(s,'B',b),null);s=resolveRound(s,a,b).state;assertState(s);}assert.equal(s.status,'Finished');
});
