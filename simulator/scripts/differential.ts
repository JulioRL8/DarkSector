/** Disposable local Anvil + real commit/reveal. No external chain or private keys. */
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createPublicClient, createWalletClient, createTestClient, http, encodeAbiParameters, keccak256 } from 'viem';
import type { Abi, Address, Hex } from 'viem';
import { foundry } from 'viem/chains';
import { createGame, resolveRound, resolveRevealTimeout, legalOrders, assertState, CAPTURABLE, sectorAt, ACTIONS } from '../src/engine/game.ts';
import type { GameState, Order, Side } from '../src/engine/game.ts';
const here=dirname(fileURLToPath(import.meta.url));
const arg=process.argv.indexOf('--repo');
const repo=arg>=0?resolve(process.argv[arg+1]):resolve(here,'../..');
if(!existsSync(join(repo,'src/DarkSector.sol')))throw new Error('Usa --repo /ruta/dark-sector para localizar el contrato.');
const temp=mkdtempSync(join(tmpdir(),'dark-sector-diff-'));
let shutdown:(()=>void)|undefined;let comparisons=0,transactions=0;
const pause=(ms:number)=>new Promise(r=>setTimeout(r,ms));
try{
 mkdirSync(join(temp,'src'));copyFileSync(join(repo,'src/DarkSector.sol'),join(temp,'src/DarkSector.sol'));
 writeFileSync(join(temp,'foundry.toml'),'[profile.default]\nsrc="src"\nout="out"\noptimizer=true\n');
 writeFileSync(join(temp,'src/DifferentialHarness.sol'),`pragma solidity ^0.8.13;
import {DarkSector,Game,Fleet,GameStatus,GameResult,RoundPhase} from "./DarkSector.sol";
contract DifferentialHarness is DarkSector {
 function prime(uint256[] calldata x) external {
  Game storage g=games[0];g.round=uint8(x[0]);g.status=GameStatus.Active;g.result=GameResult.Pending;
  g.phase=RoundPhase.Commit;g.phaseDeadline=block.timestamp+5 minutes;
  g.playerA.energy=uint32(x[3]);g.playerA.points=uint32(x[4]);g.fleetA=Fleet(uint8(x[5]),uint8(x[6]));
  g.playerB.energy=uint32(x[7]);g.playerB.points=uint32(x[8]);g.fleetB=Fleet(uint8(x[9]),uint8(x[10]));
  revealFaults[0][g.playerA.account]=uint8(x[11]);revealFaults[0][g.playerB.account]=uint8(x[12]);
  delete orders[0][g.playerA.account];delete orders[0][g.playerB.account];
  delete commitments[0][g.playerA.account];delete commitments[0][g.playerB.account];
  for(uint8 i;i<25;i++)sectorOwners[0][i]=x[13+i]==1?g.playerA.account:x[13+i]==2?g.playerB.account:address(0);
 }
 function snapshot() external view returns(uint256[] memory x) {
  Game memory g=games[0];x=new uint256[](38);x[0]=g.round;x[1]=uint256(g.status);x[2]=uint256(g.result);
  x[3]=g.playerA.energy;x[4]=g.playerA.points;x[5]=g.fleetA.position;x[6]=g.fleetA.ships;
  x[7]=g.playerB.energy;x[8]=g.playerB.points;x[9]=g.fleetB.position;x[10]=g.fleetB.ships;
  x[11]=revealFaults[0][g.playerA.account];x[12]=revealFaults[0][g.playerB.account];
  for(uint8 i;i<25;i++){address o=sectorOwners[0][i];x[13+i]=o==g.playerA.account?1:o==g.playerB.account?2:0;}
 }
}`);
 const build=spawnSync('forge',['build','--root',temp],{encoding:'utf8'});
 if(build.status!==0)throw new Error(`Solidity no compila:\n${build.stdout}\n${build.stderr}`);
 const artifact=JSON.parse(readFileSync(join(temp,'out/DifferentialHarness.sol/DifferentialHarness.json'),'utf8')) as {abi:Abi;bytecode:{object:Hex}};
 const port=await new Promise<number>((ok,bad)=>{const s=createServer();s.once('error',bad);s.listen(0,'127.0.0.1',()=>{const addr=s.address();const p=typeof addr==='object'&&addr?addr.port:0;s.close(()=>ok(p));});});
 const anvil=spawn('anvil',['--host','127.0.0.1','--port',String(port),'--silent'],{stdio:'ignore'});
 let spawnError:Error|undefined;anvil.on('error',e=>{spawnError=e;});shutdown=()=>{anvil.kill('SIGTERM');};
 const transport=http(`http://127.0.0.1:${port}`,{retryCount:0,timeout:2000});
 const client=createPublicClient({chain:foundry,transport,pollingInterval:10});
 let ready=false;for(let i=0;i<80;i++){if(spawnError)throw spawnError;try{await client.getChainId();ready=true;break;}catch{await pause(50);}}
 if(!ready)throw new Error('No se pudo iniciar Anvil.');
 const wallet=createWalletClient({chain:foundry,transport});const [a,b]=await wallet.getAddresses();
 const deployment=await wallet.deployContract({account:a,abi:artifact.abi,bytecode:artifact.bytecode.object});
 const receipt=await client.waitForTransactionReceipt({hash:deployment});const contract=receipt.contractAddress!;
 if(receipt.status!=='success')throw new Error(`Falló el despliegue local: ${artifact.bytecode.object.length} caracteres de bytecode, gas ${receipt.gasUsed}.`);
 const deployedCode=await client.getCode({address:contract});
 if(!deployedCode||deployedCode==='0x')throw new Error(`Despliegue sin código: bytecode ${artifact.bytecode.object.length} caracteres, receipt ${JSON.stringify(receipt,(_,v)=>typeof v==='bigint'?v.toString():v)}`);
 async function tx(account:Address,fn:string,args:readonly unknown[]=[]){transactions++;const hash=await wallet.writeContract({address:contract,abi:artifact.abi,functionName:fn,args,account,gas:10_000_000n});const r=await client.waitForTransactionReceipt({hash});if(r.status!=='success')throw new Error(`${fn} revirtió.`);}
 await tx(a,'createGame');await tx(b,'joinGame',[0n]);
 function vector(s:GameState):bigint[]{return [s.round,s.status==='Active'?1:2,['Pending','PlayerAWins','PlayerBWins','Draw'].indexOf(s.result),s.players.A.energy,s.players.A.points,s.players.A.position,s.players.A.ships,s.players.B.energy,s.players.B.points,s.players.B.position,s.players.B.ships,s.players.A.faults,s.players.B.faults,...s.owners.map(o=>o==='A'?1:o==='B'?2:0)].map(BigInt);}
 async function compare(s:GameState,label:string){const actual=await client.readContract({address:contract,abi:artifact.abi,functionName:'snapshot'}) as bigint[];assert.deepEqual(actual,vector(s),`Divergencia: ${label}`);assertState(s);comparisons++;}
 const salt=keccak256(new TextEncoder().encode('local differential fixtures'));
 function hash(s:GameState,who:Address,o:Order):Hex{return keccak256(encodeAbiParameters([{type:'address'},{type:'uint256'},{type:'uint256'},{type:'uint8'},{type:'address'},{type:'uint8'},{type:'uint8'},{type:'bytes32'}],[contract,31337n,0n,s.round,who,ACTIONS.indexOf(o.action),o.destination,salt]));}
 async function round(s:GameState,oa:Order,ob:Order,reverse=false){
  await tx(a,'commitOrders',[0n,hash(s,a,oa)]);await tx(b,'commitOrders',[0n,hash(s,b,ob)]);
  const entries=reverse?[[b,ob],[a,oa]] as const:[[a,oa],[b,ob]] as const;
  for(const [who,o] of entries)await tx(who,'revealOrders',[0n,ACTIONS.indexOf(o.action),o.destination,salt]);
  return resolveRound(s,oa,ob).state;
 }
 let seed=0xD4A5EC;const initialSeed=seed;const random=(n:number)=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
 for(let i=0;i<96;i++){
  const s=createGame();s.round=1+random(10);const cells=Array.from({length:25},(_,p)=>p).filter(p=>sectorAt(p)!=='obstacle');
  for(const side of ['A','B'] as Side[]){const p=s.players[side];p.energy=random(15);p.points=random(30);p.ships=random(11);const allowed=cells.filter(c=>c!==(side==='A'?24:0));p.position=p.ships?allowed[random(allowed.length)]:side==='A'?0:24;}
  while(s.players.A.ships&&s.players.B.ships&&s.players.A.position===s.players.B.position)s.players.B.position=cells.filter(c=>c!==0)[random(cells.length-1)];
  for(const p of CAPTURABLE)s.owners[p]=[null,'A','B'][random(3)] as Side|null;
  const choose=(side:Side):Order=>{const options=legalOrders(s,side);return random(3)?options[random(options.length)]:{action:ACTIONS[random(5)],destination:random(26)};};
  let oa=choose('A'),ob=choose('B');
  if(i<32){s.players.A.position=1;s.players.B.position=2;s.players.A.ships=1+random(10);s.players.B.ships=1+random(10);s.players.A.energy=5;s.players.B.energy=5;oa={action:'Move',destination:2};ob=i%2?{action:'Defend',destination:0}:{action:'Move',destination:1};}
  if(i>=32&&i<40){s.players.A.position=0;s.players.B.position=24;s.players.A.energy=i%2?2:5;s.players.B.energy=5;oa={action:'Build',destination:0};ob={action:'Build',destination:0};}
  await tx(a,'prime',[vector(s)]);const result=await round(s,oa,ob,i%2===0);await compare(result,`fixture ${i}: ${JSON.stringify({s,oa,ob})}`);
 }
 for(let match=0;match<4;match++){
  let s=createGame();await tx(a,'prime',[vector(s)]);
  for(let r=0;r<10;r++){const pick=(side:Side)=>{const options=legalOrders(s,side);return options[random(options.length)];};s=await round(s,pick('A'),pick('B'),r%2===0);await compare(s,`partida ${match}, ronda ${r+1}`);}
 }
 const tc=createTestClient({chain:foundry,mode:'anvil',transport});
 async function timeout(){const data=await client.readContract({address:contract,abi:artifact.abi,functionName:'getGame',args:[0n]}) as {phaseDeadline:bigint};await tc.setNextBlockTimestamp({timestamp:data.phaseDeadline});await tx(a,'advanceAfterTimeout',[0n]);}
 let s=createGame();await tx(a,'prime',[vector(s)]);await timeout();s=resolveRound(s).state;await compare(s,'sin compromisos');
 await tx(a,'commitOrders',[0n,hash(s,a,{action:'Move',destination:1})]);await timeout();await tx(a,'revealOrders',[0n,1,1,salt]);s=resolveRound(s,{action:'Move',destination:1}).state;await compare(s,'un compromiso');
 for(let i=0;i<2;i++){const hold:Order={action:'Hold',destination:0};await tx(a,'commitOrders',[0n,hash(s,a,hold)]);await tx(b,'commitOrders',[0n,hash(s,b,hold)]);await tx(a,'revealOrders',[0n,0,0,salt]);await timeout();s=resolveRevealTimeout(s,{A:true,B:true},{A:hold}).state;await compare(s,`falta ${i+1}`);}
 const report={passed:true,comparisons,transactions,seed:initialSeed,contract:'src/DarkSector.sol',contractSha256:createHash('sha256').update(readFileSync(join(repo,'src/DarkSector.sol'))).digest('hex'),generatedAt:new Date().toISOString()};
 mkdirSync(resolve(here,'../reports'),{recursive:true});writeFileSync(resolve(here,'../reports/differential.json'),JSON.stringify(report,null,2));
 console.log(`✓ ${comparisons} estados coinciden entre TypeScript y Solidity (${transactions} transacciones locales).`);
}catch(error){console.error(error);process.exitCode=1;}finally{shutdown?.();rmSync(temp,{recursive:true,force:true});}
