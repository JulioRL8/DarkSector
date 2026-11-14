import { legalOrders, CAPTURABLE, other } from './game.ts';
import type { GameState, Order, Side } from './game.ts';
function distance(from: number, to: number): number { return Math.abs(Math.floor(from / 5) - Math.floor(to / 5)) + Math.abs(from % 5 - to % 5); }
/** A transparent heuristic opponent, not an optimal search or a source of game rules. */
export function suggestOrder(state: GameState, side: Side): Order {
  const options = legalOrders(state, side); const p = state.players[side]; const rival = state.players[other(side)];
  const target = CAPTURABLE.filter(pos => state.owners[pos] !== side).sort((a,b) => distance(p.position,a) - distance(p.position,b))[0];
  const score = (o: Order): number => {
    if (o.action === 'Capture') return 30;
    if (o.action === 'Build') return p.ships === 0 ? 100 : p.ships < 5 ? 15 : -2;
    if (o.action === 'Defend') return distance(p.position, rival.position) === 1 && rival.ships >= p.ships ? 8 : -1;
    if (o.action === 'Move') {
      if (o.destination === rival.position && rival.ships >= p.ships) return -20;
      return target === undefined ? -3 : 10 - distance(o.destination, target) * 2;
    }
    return 0;
  };
  return [...options].sort((a,b) => score(b) - score(a))[0] ?? { action: 'Hold', destination: 0 };
}
