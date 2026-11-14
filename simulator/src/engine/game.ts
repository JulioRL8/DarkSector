/** Independent, deterministic specification of the Dark Sector rules. No RPC or DOM. */
export type Side = 'A' | 'B';
export type Action = 'Hold' | 'Move' | 'Capture' | 'Defend' | 'Build';
export type Sector = 'empty' | 'obstacle' | 'station' | 'core' | 'base';
export type Outcome = 'Pending' | 'PlayerAWins' | 'PlayerBWins' | 'Draw';
export interface Player { energy: number; points: number; position: number; ships: number; faults: number }
export interface GameState {
  round: number; status: 'Active' | 'Finished'; result: Outcome;
  players: Record<Side, Player>; owners: (Side | null)[];
}
export interface Order { action: Action; destination: number }
export interface GameEvent { kind: 'move' | 'combat' | 'destroy' | 'capture' | 'build' | 'income' | 'invalid' | 'fault' | 'finish'; text: string }
export interface RoundResult { state: GameState; events: GameEvent[]; effectiveOrders: Record<Side, Order> }
export const SIDES: Side[] = ['A', 'B'];
export const ACTIONS: Action[] = ['Hold', 'Move', 'Capture', 'Defend', 'Build'];
export const BASE: Record<Side, number> = { A: 0, B: 24 };
export const HOLD: Order = { action: 'Hold', destination: 0 };
export const STATIONS = [2, 10, 14, 22];
export const CAPTURABLE = [...STATIONS, 12];
export const other = (side: Side): Side => side === 'A' ? 'B' : 'A';
export function sectorAt(position: number): Sector {
  if (!Number.isInteger(position) || position < 0 || position > 24) throw new Error('Sector fuera del tablero.');
  if ([0, 24].includes(position)) return 'base';
  if ([6, 8, 16, 18].includes(position)) return 'obstacle';
  if (position === 12) return 'core';
  return STATIONS.includes(position) ? 'station' : 'empty';
}
export function createGame(): GameState {
  return { round: 1, status: 'Active', result: 'Pending', owners: Array(25).fill(null),
    players: { A: { energy: 5, points: 0, position: 0, ships: 3, faults: 0 },
      B: { energy: 5, points: 0, position: 24, ships: 3, faults: 0 } } };
}
/** Returns a human explanation; null means the order is legal before resolution. */
export function invalidReason(state: GameState, side: Side, order: Order): string | null {
  if (state.status !== 'Active') return 'La partida ha terminado.';
  const p = state.players[side];
  if (!ACTIONS.includes(order.action)) return 'Acción desconocida.';
  if (!Number.isInteger(order.destination) || order.destination < 0 || order.destination > 255) return 'Destino fuera del formato uint8.';
  switch (order.action) {
    case 'Hold': return null;
    case 'Move': {
      if (p.ships === 0) return 'Reconstruye tu flota antes de moverte.';
      if (p.energy < 1) return 'Necesitas 1 de energía.';
      const d = order.destination;
      if (d > 24) return 'El destino está fuera del tablero.';
      const distance = Math.abs(Math.floor(p.position / 5) - Math.floor(d / 5)) + Math.abs(p.position % 5 - d % 5);
      if (distance !== 1) return 'Elige una casilla adyacente horizontal o vertical.';
      if (sectorAt(d) === 'obstacle') return 'Los asteroides son inaccesibles.';
      if (d === BASE[other(side)]) return 'No puedes entrar en la base enemiga.';
      return null;
    }
    case 'Capture':
      if (p.ships === 0) return 'Una flota destruida no puede capturar.';
      if (!CAPTURABLE.includes(p.position)) return 'Solo se capturan estaciones y el núcleo.';
      return state.owners[p.position] === side ? 'Ya controlas este sector.' : null;
    case 'Defend': return p.ships === 0 ? 'Necesitas una flota para defender.' : null;
    case 'Build':
      if (p.energy < 3) return 'Necesitas 3 de energía antes de recibir ingresos.';
      if (p.position !== BASE[side]) return 'Construye en tu base.';
      return p.ships >= 10 ? 'El límite es de 10 naves.' : null;
  }
}
export function legalOrders(state: GameState, side: Side): Order[] {
  const options: Order[] = ACTIONS.filter(a => a !== 'Move').map(action => ({ action, destination: 0 }));
  for (let destination = 0; destination < 25; destination++) options.push({ action: 'Move', destination });
  return options.filter(order => !invalidReason(state, side, order));
}
export function combatSurvivors(a: number, b: number, defendA: boolean, defendB: boolean): [number, number] {
  return [Math.max(0, a - b - Number(defendB)), Math.max(0, b - a - Number(defendA))];
}
function determineWinner(state: GameState): Outcome {
  const points = state.players.A.points - state.players.B.points;
  const stations = STATIONS.reduce((score, p) => score + (state.owners[p] === 'A' ? 1 : state.owners[p] === 'B' ? -1 : 0), 0);
  const score = points || stations;
  return score > 0 ? 'PlayerAWins' : score < 0 ? 'PlayerBWins' : 'Draw';
}
export function resolveRound(input: GameState, orderA: Order = HOLD, orderB: Order = HOLD): RoundResult {
  if (input.status !== 'Active') throw new Error('La partida ya ha terminado.');
  const state = structuredClone(input);
  const events: GameEvent[] = [];
  const effectiveOrders = { A: { ...orderA }, B: { ...orderB } };
  for (const side of SIDES) {
    const reason = invalidReason(input, side, effectiveOrders[side]);
    if (reason) { effectiveOrders[side] = { ...HOLD }; events.push({ kind: 'invalid', text: `${side}: orden convertida en espera. ${reason}` }); }
  }
  const origins = { A: input.players.A.position, B: input.players.B.position };
  const targets = { A: origins.A, B: origins.B };
  for (const side of SIDES) if (effectiveOrders[side].action === 'Move') {
    targets[side] = effectiveOrders[side].destination;
    state.players[side].energy--;
  }
  const swapping = effectiveOrders.A.action === 'Move' && effectiveOrders.B.action === 'Move' && targets.A === origins.B && targets.B === origins.A;
  const fighting = input.players.A.ships > 0 && input.players.B.ships > 0 && (targets.A === targets.B || swapping);
  if (fighting) {
    const [a, b] = combatSurvivors(input.players.A.ships, input.players.B.ships, effectiveOrders.A.action === 'Defend', effectiveOrders.B.action === 'Defend');
    events.push({ kind: 'combat', text: `Combate${swapping ? ' en tránsito' : ` en sector ${targets.A}`}: A pierde ${input.players.A.ships - a}; B pierde ${input.players.B.ships - b}.` });
    state.players.A.ships = a; state.players.B.ships = b;
    for (const side of SIDES) {
      const p = state.players[side];
      p.position = p.ships === 0 ? BASE[side] : swapping ? origins[side] : targets[side];
      if (p.ships === 0) events.push({ kind: 'destroy', text: `${side}: flota destruida. Puede reconstruir en su base.` });
      else if (p.position !== origins[side]) events.push({ kind: 'move', text: `${side}: ${origins[side]} → ${p.position}. −1 energía.` });
    }
  } else for (const side of SIDES) if (effectiveOrders[side].action === 'Move') {
    state.players[side].position = targets[side];
    events.push({ kind: 'move', text: `${side}: ${origins[side]} → ${targets[side]}. −1 energía.` });
  }
  for (const side of SIDES) {
    const p = state.players[side];
    if (effectiveOrders[side].action === 'Capture' && p.ships > 0) {
      state.owners[p.position] = side;
      events.push({ kind: 'capture', text: `${side} captura ${p.position === 12 ? 'el núcleo' : `la estación ${p.position}`}.` });
    }
    if (effectiveOrders[side].action === 'Build') {
      p.energy -= 3; p.ships++;
      events.push({ kind: 'build', text: `${side}: nave construida. Flota de ${p.ships}. −3 energía.` });
    }
  }
  for (const side of SIDES) {
    const p = state.players[side];
    const sectors = CAPTURABLE.filter(pos => state.owners[pos] === side);
    const points = sectors.reduce((sum, pos) => sum + (pos === 12 ? 3 : 1), 0);
    p.energy += 2 + sectors.length; p.points += points;
    events.push({ kind: 'income', text: `${side}: +${2 + sectors.length} energía · +${points} puntos.` });
  }
  if (state.round === 10) {
    state.status = 'Finished'; state.result = determineWinner(state);
    events.push({ kind: 'finish', text: outcomeLabel(state.result) });
  } else state.round++;
  return { state, events, effectiveOrders };
}
/** Commit flags distinguish absence from a commitment withheld after seeing the rival's reveal. */
export function resolveRevealTimeout(input: GameState, committed: Record<Side, boolean>, revealed: Partial<Record<Side, Order>>): RoundResult {
  if (input.status !== 'Active') throw new Error('La partida ya ha terminado.');
  const state = structuredClone(input); const events: GameEvent[] = [];
  for (const side of SIDES) {
    if (revealed[side] && !committed[side]) throw new Error('No se puede revelar sin compromiso.');
    if (committed[side] && !revealed[side]) {
      state.players[side].faults++; events.push({ kind: 'fault', text: `${side}: falta de revelación (${state.players[side].faults}/2).` });
    }
  }
  const losesA = state.players.A.faults >= 2, losesB = state.players.B.faults >= 2;
  if (losesA || losesB) {
    state.status = 'Finished'; state.result = losesA && losesB ? 'Draw' : losesA ? 'PlayerBWins' : 'PlayerAWins';
    events.push({ kind: 'finish', text: `${outcomeLabel(state.result)} Final por abandono; sin ejecutar esta ronda.` });
    return { state, events, effectiveOrders: { A: { ...HOLD }, B: { ...HOLD } } };
  }
  const resolved = resolveRound(state, revealed.A ?? HOLD, revealed.B ?? HOLD);
  return { ...resolved, events: [...events, ...resolved.events] };
}
export function outcomeLabel(result: Outcome): string {
  return ({ Pending: 'Partida en curso', PlayerAWins: 'Victoria de Helios · A', PlayerBWins: 'Victoria de Umbra · B', Draw: 'Empate' })[result];
}
export function assertState(state: GameState): void {
  if (!Number.isInteger(state.round) || state.round < 1 || state.round > 10) throw new Error('Ronda inválida.');
  if (state.owners.length !== 25 || state.owners.some(x => x !== null && x !== 'A' && x !== 'B')) throw new Error('Propietarios inválidos.');
  for (const side of SIDES) {
    const p = state.players[side];
    if (![p.energy,p.points,p.position,p.ships,p.faults].every(Number.isInteger) || p.energy < 0 || p.points < 0 || p.ships < 0 || p.ships > 10 || p.faults < 0 || p.faults > 2) throw new Error('Recursos inválidos.');
    if (sectorAt(p.position) === 'obstacle') throw new Error('Flota en un obstáculo.');
    if (p.ships && p.position === BASE[other(side)]) throw new Error('Flota en la base enemiga.');
    if (!p.ships && p.position !== BASE[side]) throw new Error('Flota destruida fuera de su base.');
  }
  if (state.players.A.ships && state.players.B.ships && state.players.A.position === state.players.B.position) throw new Error('Dos flotas vivas comparten sector.');
}
