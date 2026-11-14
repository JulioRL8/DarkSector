import './style.css';
import { SIDES, BASE, STATIONS, CAPTURABLE, HOLD, sectorAt, invalidReason, resolveRound, outcomeLabel, legalOrders } from './engine/game.ts';
import type { Side, Order, Action, GameState } from './engine/game.ts';
import { SCENARIOS, replayTimeline, parseReplay } from './engine/replay.ts';
import type { Replay, Scenario } from './engine/replay.ts';
import { suggestOrder } from './engine/bot.ts';

const root = document.querySelector<HTMLDivElement>('#app')!;
const KEY = 'dark-sector-replay-v1';
let replay: Replay = { version: 1, scenario: 'standard', turns: [] };
let notice = '';
try { const saved = localStorage.getItem(KEY); if (saved) replay = parseReplay(saved); } catch { notice = 'No se pudo recuperar la partida guardada. Puedes empezar una nueva.'; }
let timeline = replayTimeline(replay);
let cursor = replay.turns.length;
let selected: Side = 'A';
let orders: Record<Side, Order> = { A: { ...HOLD }, B: { ...HOLD } };
let bot = false;
let autoTimer: ReturnType<typeof setInterval> | null = null;
let confirmReset = false;
const names = { A: 'Helios', B: 'Umbra' };
const actionNames: Record<Action,string> = { Hold:'Esperar', Move:'Mover', Capture:'Capturar', Defend:'Defender', Build:'Construir' };
const actionInfo: Record<Action,string> = { Hold:'Conserva tu posición y recibe ingresos.', Move:'Elige un sector iluminado. Coste: 1 energía, incluso si hay combate.', Capture:'Toma la estación o el núcleo actual. Produce desde esta ronda.', Defend:'Permanece en tu sector y suma 1 de fuerza en combate.', Build:'Añade una nave en tu base. Coste: 3 energía. Máximo: 10 naves.' };
const symbols = { empty:'', obstacle:'✦', station:'◇', core:'◈', base:'⌂' };
const labels = { empty:'Espacio vacío', obstacle:'Asteroides', station:'Estación', core:'Núcleo', base:'Base' };
const escape = (s: string) => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const state = () => timeline.states[cursor];
function stopAuto() { if (autoTimer) clearInterval(autoTimer); autoTimer = null; }
function save() { try { localStorage.setItem(KEY, JSON.stringify(replay)); } catch { notice = 'La partida funciona, pero el navegador no permite guardarla. Expórtala para conservarla.'; } }
function fresh(scenario: Scenario) {
  stopAuto(); replay = { version:1, scenario, turns:[] }; timeline = replayTimeline(replay); cursor = 0;
  orders = { A: {...HOLD}, B: {...HOLD} }; confirmReset = false; notice = ''; save(); render();
}
function income(s: GameState, side: Side) {
  const owned = CAPTURABLE.filter(p => s.owners[p] === side);
  return { energy:2+owned.length, points:owned.reduce((n,p)=>n+(p===12?3:1),0) };
}
function playerCard(side: Side) {
  const p = state().players[side]; const inc = income(state(), side);
  return `<button class="player-card ${side.toLowerCase()} ${selected===side?'selected':''}" data-side="${side}" aria-pressed="${selected===side}">
    <span class="card-kicker">FLOTA ${side} <span class="side-dot"></span></span>
    <span class="faction">${names[side]} <span class="faction-code">${side==='A'?'SOL / 01':'NOX / 02'}</span></span>
    <span class="metrics"><span><b>${p.points}</b><small>PUNTOS</small></span><span><b>${p.energy}</b><small>ENERGÍA</small></span><span><b>${p.ships}</b><small>NAVES</small></span></span>
    <span class="card-footer">${p.ships ? `Sector ${String(p.position).padStart(2,'0')}` : 'Flota destruida'}<span>+${inc.energy} ⚡ / +${inc.points} pts por ronda</span></span>
  </button>`;
}
function board() {
  const s = state(); const editable = cursor === replay.turns.length && s.status === 'Active';
  const destinations = new Set(legalOrders(s, selected).filter(o=>o.action==='Move').map(o=>o.destination));
  const cells = Array.from({length:25},(_,p)=> {
    const sector = sectorAt(p); const owner = s.owners[p]; const occupants = SIDES.filter(side=>s.players[side].ships>0 && s.players[side].position===p);
    const fleet = occupants[0]; const target = orders[selected].action==='Move' && orders[selected].destination===p;
    const available = editable && orders[selected].action==='Move' && destinations.has(p);
    const ownedClass = owner ? `owned-${owner.toLowerCase()}` : '';
    return `<button class="cell ${sector} ${ownedClass} ${fleet?'has-fleet fleet-'+fleet.toLowerCase():''} ${target&&editable?'target':''} ${available?'available':''}" data-cell="${p}" aria-label="Sector ${p}: ${labels[sector]}${owner?', controla '+names[owner]:''}${fleet?', flota '+names[fleet]+', '+s.players[fleet].ships+' naves':''}${available?', destino válido':''}">
      <span class="cell-id">${String(p).padStart(2,'0')}</span><span class="sector-symbol" aria-hidden="true">${symbols[sector]}</span>
      ${fleet?`<span class="fleet-token"><svg viewBox="0 0 32 32" aria-hidden="true"><path d="M16 3 28 27 16 22 4 27Z"/><path d="M16 10v12"/></svg><b>${s.players[fleet].ships}</b></span>`:''}
      <span class="cell-bottom">${sector==='base'?(p===0?'HELIOS':'UMBRA'):sector==='station'?'ESTACIÓN':sector==='core'?'NÚCLEO':''}${owner?` <i>${owner}</i>`:''}</span>
      ${available?'<span class="destination-mark">+</span>':''}
    </button>`;
  }).join('');
  return `<div class="board-frame"><div class="board-top"><span>SECTOR Ω / CUADRANTE 05</span><span><i class="live-dot"></i> SIMULACIÓN LOCAL</span></div><div class="board" role="group" aria-label="Tablero espacial de 5 por 5">${cells}</div><div class="board-bottom"><span>◇ Estación <b>+1 ⚡ · +1 pt</b></span><span>◈ Núcleo <b>+1 ⚡ · +3 pts</b></span><span>✦ Inaccesible</span></div></div>`;
}
function commandPanel() {
  const s = state(); const o = bot && selected === 'B' ? suggestOrder(s, 'B') : orders[selected]; const reason = invalidReason(s,selected,o);
  const reviewing = cursor < replay.turns.length;
  const disabled = reviewing || s.status === 'Finished';
  const preview = !disabled ? resolveRound(s,orders.A,bot?suggestOrder(s,'B'):orders.B) : null;
  const p = preview?.state.players[selected];
  return `<section class="command-panel"><div class="panel-heading"><span class="eyebrow">CENTRO DE MANDO</span><span class="badge ${selected.toLowerCase()}">FLOTA ${selected}</span></div>
    <h2>Tu próximo movimiento.</h2><p class="muted">${reviewing?'Estás viendo una ronda anterior. Vuelve al presente para dar órdenes.':s.status==='Finished'?'Expedición completada. Recorre la repetición o empieza otra.':`Planifica la orden de ${names[selected]}. Las dos flotas actúan a la vez.`}</p>
    <div class="side-switch" role="group" aria-label="Seleccionar jugador"><button data-side="A" class="${selected==='A'?'active a':''}">A · Helios</button><button data-side="B" class="${selected==='B'?'active b':''}">B · Umbra</button></div>
    <label class="bot-toggle"><input id="bot" type="checkbox" ${bot?'checked':''} ${disabled?'disabled':''}> Rival automático <span>Umbra · heurística</span></label>
    <div class="actions">${(['Move','Capture','Defend','Build','Hold'] as Action[]).map(action=>`<button data-action="${action}" class="action ${o.action===action?'chosen':''}" ${disabled || (bot&&selected==='B')?'disabled':''}><span>${({Move:'↗',Capture:'⚑',Defend:'⬡',Build:'+',Hold:'Ⅱ'})[action]}</span>${actionNames[action]}<small>${action==='Move'?'1 ⚡':action==='Build'?'3 ⚡':'0 ⚡'}</small></button>`).join('')}</div>
    <div class="order-detail"><b>${actionNames[o.action]}${o.action==='Move'?' → sector '+o.destination:''}</b><p>${actionInfo[o.action]}</p>${reason&&!disabled?`<p class="warning">${reason} Esta orden se resolvería como espera.</p>`:''}</div>
    ${preview&&p?`<div class="forecast"><span>PREVISIÓN · ÓRDENES ACTUALES</span><div><b>${p.ships} naves</b><b>${p.energy} ⚡</b><b>${p.points} pts</b></div><small>Incluye combate e ingresos. No es una predicción del rival.</small></div>`:''}
    <button id="resolve" class="primary" ${disabled?'disabled':''}>Resolver ronda ${s.round}<span>↗</span></button>
    <p class="local-note">Modo laboratorio: controlas ambos bandos. Sin wallet ni transacciones. Las órdenes no son secretas en este simulador.</p>
  </section>`;
}
function historyPanel() {
  const result = timeline.results[cursor-1];
  return `<section class="history-panel"><div class="history-head"><div><span class="eyebrow">REGISTRO DE MISIÓN</span><h2>${cursor?'Resolución de la ronda '+timeline.states[cursor-1].round:'Esperando órdenes'}</h2></div><span class="badge">${cursor} / ${replay.turns.length}</span></div>
    <div class="timeline"><button data-step="-1" aria-label="Ronda anterior" ${cursor===0?'disabled':''}>←</button><input id="timeline" aria-label="Explorar historial de rondas" type="range" min="0" max="${replay.turns.length}" value="${cursor}"><button data-step="1" aria-label="Ronda siguiente" ${cursor===replay.turns.length?'disabled':''}>→</button><button id="present" ${cursor===replay.turns.length?'disabled':''}>Presente</button></div>
    <div class="event-list">${result?result.events.map(e=>`<div class="event"><span class="event-dot ${e.kind}"></span><p>${escape(e.text)}</p><small>${e.kind==='combat'?'COMBATE':e.kind==='capture'?'CONTROL':e.kind==='income'?'RECURSOS':'EVENTO'}</small></div>`).join(''):'<div class="empty-state"><span>⌁</span><p>El espacio está en silencio.<br><small>Selecciona una flota y prepara la primera ronda.</small></p></div>'}</div>
  </section>`;
}
function render() {
  timeline = replayTimeline(replay); const s = state();
  root.innerHTML = `<div class="shell"><header><a class="brand" href="#" aria-label="Dark Sector inicio"><span class="brand-mark">◈</span><span>DARK<span class="brand-light">SECTOR</span><small>TACTICAL SIMULATOR / V1.0</small></span></a><div class="header-actions"><button id="rules">Cómo jugar <span>↗</span></button><button id="export">Exportar</button><label class="file-button">Importar<input id="import" type="file" accept="application/json,.json"></label></div></header>
    <main><section class="intro"><div><div class="eyebrow"><span class="live-dot"></span> LABORATORIO DE ESTRATEGIA</div><h1>El espacio se conquista<br><em>una decisión a la vez.</em></h1><p>Explora. Anticipa. Controla el núcleo antes que tu rival.</p></div><div class="round-dial"><span>RONDA</span><b>${String(s.round).padStart(2,'0')}<small>/ 10</small></b><span>${s.status==='Finished'?'MISIÓN COMPLETADA':cursor<replay.turns.length?'REPETICIÓN':'PLANIFICACIÓN'}</span></div></section>
    ${notice?`<div class="notice" role="status">${escape(notice)}<button id="dismiss" aria-label="Cerrar aviso">×</button></div>`:''}
    ${s.status==='Finished'?`<div class="outcome" role="status"><span>EXPEDICIÓN FINALIZADA</span><h2>${outcomeLabel(s.result)}</h2><p>Helios ${s.players.A.points} · Umbra ${s.players.B.points}. El desempate utiliza estaciones; excluye el núcleo.</p></div>`:''}
    <div class="workspace"><div class="left-column"><div class="players">${playerCard('A')}${playerCard('B')}</div>${board()}<div class="scenario-bar"><label>ESCENARIO <select id="scenario">${Object.entries(SCENARIOS).map(([k,v])=>`<option value="${k}" ${replay.scenario===k?'selected':''}>${v.title}</option>`).join('')}</select></label><button id="auto" ${s.status==='Finished'||cursor!==replay.turns.length?'disabled':''}>${autoTimer?'Detener demo':'▶ Demo automática'}</button><button id="reset">${confirmReset?'Confirmar reinicio':'Reiniciar'}</button></div><p class="scenario-caption">${SCENARIOS[replay.scenario].description}</p></div>${commandPanel()}</div>
    ${historyPanel()}
    <footer><span>DARK SECTOR <span class="muted">/ Motor determinista en TypeScript</span></span><span>Guardado en este navegador · Sin conexión a blockchain</span></footer></main></div>
    <dialog id="rules-dialog"><div class="dialog-head"><span class="eyebrow">MANUAL DE EXPEDICIÓN</span><button id="close-rules" aria-label="Cerrar manual">×</button></div><h2>Diez rondas. Un sector.</h2><p>Consigue más puntos controlando estaciones y el núcleo. Selecciona cada flota, prepara sus órdenes y resuelve ambas a la vez.</p><ol><li><b>Mover:</b> una casilla horizontal o vertical por 1 energía. Una colisión provoca combate.</li><li><b>Capturar:</b> ocupa una ronda en una estación o núcleo. El control persiste aunque te marches.</li><li><b>Defender:</b> añade 1 de fuerza; las bajas de ambos bandos se aplican simultáneamente.</li><li><b>Construir:</b> añade una nave en tu base por 3 energía. También reconstruye una flota destruida.</li></ol><p>Tu base genera 2 energía. Cada estación añade 1 energía y 1 punto; el núcleo añade 1 energía y 3 puntos. Los ingresos se entregan al final, incluso en la ronda diez.</p><p>En un intercambio de posiciones, los supervivientes quedan en su origen. Si empatan a puntos, gana quien controle más estaciones. Un empate total es empate.</p><p class="muted">La aplicación simula la resolución del juego. El protocolo de hashes y los vencimientos se verifican en las pruebas de Solidity; no se envían transacciones desde esta pantalla.</p></dialog>`;
  bind();
}
function resolve(automatic = false) {
  if (cursor !== replay.turns.length || state().status !== 'Active') return;
  const turn = { A: automatic?suggestOrder(state(),'A'):{...orders.A}, B: automatic||bot?suggestOrder(state(),'B'):{...orders.B} };
  replay.turns.push(turn); cursor = replay.turns.length; orders = { A:{...HOLD},B:{...HOLD} }; confirmReset = false;
  if (replayTimeline(replay).states.at(-1)?.status==='Finished') stopAuto(); save(); render();
}
function bind() {
  root.querySelectorAll<HTMLButtonElement>('[data-side]').forEach(el=>el.onclick=()=>{selected=el.dataset.side as Side;render();});
  root.querySelectorAll<HTMLButtonElement>('[data-action]').forEach(el=>el.onclick=()=> {
    const action=el.dataset.action as Action;
    const first=legalOrders(state(),selected).find(o=>o.action===action);
    orders[selected]={action,destination:action==='Move'?(first?.destination??state().players[selected].position):0};render();
  });
  root.querySelectorAll<HTMLButtonElement>('[data-cell]').forEach(el=>el.onclick=()=> {
    const p=Number(el.dataset.cell);
    if(cursor===replay.turns.length&&state().status==='Active'&&orders[selected].action==='Move'&&!(bot&&selected==='B')) {
      const candidate: Order={action:'Move',destination:p};
      if(!invalidReason(state(),selected,candidate)){orders[selected]=candidate;render();return;}
    }
    notice=`Sector ${p}: ${labels[sectorAt(p)]}${state().owners[p]?'. Control: '+names[state().owners[p]!]:''}.`;render();
  });
  document.querySelector<HTMLButtonElement>('#resolve')!.onclick=()=>resolve();
  document.querySelector<HTMLInputElement>('#bot')!.onchange=e=>{bot=(e.target as HTMLInputElement).checked;if(bot)selected='A';render();};
  root.querySelectorAll<HTMLButtonElement>('[data-step]').forEach(el=>el.onclick=()=>{stopAuto();cursor+=Number(el.dataset.step);render();});
  document.querySelector<HTMLInputElement>('#timeline')!.oninput=e=>{stopAuto();cursor=Number((e.target as HTMLInputElement).value);render();};
  document.querySelector<HTMLButtonElement>('#present')!.onclick=()=>{cursor=replay.turns.length;render();};
  document.querySelector<HTMLSelectElement>('#scenario')!.onchange=e=> {
    const next=(e.target as HTMLSelectElement).value as Scenario;
    if(replay.turns.length&&!window.confirm('Cambiar de escenario reinicia esta partida. Puedes exportarla antes. ¿Continuar?')){render();return;}
    fresh(next);
  };
  document.querySelector<HTMLButtonElement>('#reset')!.onclick=()=>{if(!confirmReset&&replay.turns.length){confirmReset=true;render();}else fresh(replay.scenario);};
  document.querySelector<HTMLButtonElement>('#auto')!.onclick=()=> {
    if(autoTimer){stopAuto();render();return;}
    autoTimer=setInterval(()=>resolve(true),1100);render();
  };
  document.querySelector<HTMLButtonElement>('#export')!.onclick=()=> {
    const blob=new Blob([JSON.stringify(replay,null,2)],{type:'application/json'});const url=URL.createObjectURL(blob);
    const link=document.createElement('a');link.href=url;link.download=`dark-sector-${replay.scenario}.json`;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  };
  document.querySelector<HTMLInputElement>('#import')!.onchange=async e=> {
    const file=(e.target as HTMLInputElement).files?.[0];if(!file)return;
    stopAuto();try {
      if(file.size>100_000)throw new Error('El archivo es demasiado grande.');
      const imported=parseReplay(await file.text());replay=imported;cursor=replay.turns.length;orders={A:{...HOLD},B:{...HOLD}};notice='Repetición importada y recalculada correctamente.';save();
    }catch(err){notice=err instanceof Error?err.message:'No se pudo importar el archivo.';}render();
  };
  const dialog=document.querySelector<HTMLDialogElement>('#rules-dialog')!;
  document.querySelector<HTMLButtonElement>('#rules')!.onclick=()=>dialog.showModal();
  document.querySelector<HTMLButtonElement>('#close-rules')!.onclick=()=>dialog.close();
  document.querySelector<HTMLButtonElement>('#dismiss')?.addEventListener('click',()=>{notice='';render();});
  root.querySelector<HTMLAnchorElement>('.brand')!.onclick=e=>{e.preventDefault();window.scrollTo({top:0,behavior:'smooth'});};
}
render();
