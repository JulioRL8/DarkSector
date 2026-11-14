import { createGame, resolveRound, assertState, ACTIONS } from './game.ts';
import type { GameState, Order, RoundResult } from './game.ts';
export type Scenario = 'standard' | 'combat' | 'defense' | 'rebuild' | 'final';
export const SCENARIOS: Record<Scenario, { title: string; description: string }> = {
  standard: { title: 'Nueva expedición', description: 'La partida completa: dos bases, tres naves y diez rondas.' },
  combat: { title: 'Contacto hostil', description: 'Tres naves de Helios frente a una de Umbra. Prueba un ataque.' },
  defense: { title: 'Última defensa', description: 'Tres contra dos. Defender puede provocar destrucción mutua.' },
  rebuild: { title: 'Volver a empezar', description: 'Ambas flotas destruidas. Construye una nave para regresar al tablero.' },
  final: { title: 'La última ronda', description: 'Ronda diez: una captura puede decidir el resultado final.' },
};
export function scenarioState(scenario: Scenario): GameState {
  const s = createGame();
  if (scenario === 'combat' || scenario === 'defense') {
    s.players.A.position = 1; s.players.B.position = 2;
    s.players.B.ships = scenario === 'combat' ? 1 : 2;
  }
  if (scenario === 'rebuild') { s.players.A.ships = 0; s.players.B.ships = 0; }
  if (scenario === 'final') {
    s.round = 10; s.players.A.position = 2; s.players.B.position = 22;
    s.players.A.points = 7; s.players.B.points = 8;
  }
  return s;
}
export interface Turn { A: Order; B: Order }
export interface Replay { version: 1; scenario: Scenario; turns: Turn[] }
export interface Timeline { states: GameState[]; results: RoundResult[] }
export function replayTimeline(replay: Replay): Timeline {
  let state = scenarioState(replay.scenario);
  const states = [state]; const results: RoundResult[] = [];
  for (const turn of replay.turns) {
    const result = resolveRound(state, turn.A, turn.B); assertState(result.state);
    results.push(result); state = result.state; states.push(state);
  }
  return { states, results };
}
export function parseReplay(text: string): Replay {
  if (text.length > 100_000) throw new Error('El archivo es demasiado grande.');
  const x = JSON.parse(text) as Partial<Replay>;
  if (!x || x.version !== 1 || !x.scenario || !Object.hasOwn(SCENARIOS, x.scenario) || !Array.isArray(x.turns) || x.turns.length > 10) throw new Error('Archivo de repetición no válido.');
  for (const turn of x.turns) {
    for (const side of ['A','B'] as const) {
      const o = turn?.[side];
      if (!o || !ACTIONS.includes(o.action) || !Number.isInteger(o.destination) || o.destination < 0 || o.destination > 255) throw new Error('Orden no válida en la repetición.');
    }
  }
  // Recompute every state instead of trusting snapshots imported from a file.
  const safe: Replay = { version: 1, scenario: x.scenario, turns: x.turns.map(t => ({ A: {action:t.A.action,destination:t.A.destination}, B: {action:t.B.action,destination:t.B.destination} })) };
  replayTimeline(safe); return safe;
}
