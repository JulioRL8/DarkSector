// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {GameTestBase} from "./GameTestBase.sol";
import {DarkSector, ActionType, Game, Order, OrderCommitment} from "../src/DarkSector.sol";

contract MovementHarness is DarkSector {
    function position(uint256 id, uint8 a, uint8 b) external {
        games[id].fleetA.position = a;
        games[id].fleetB.position = b;
    }

    function energy(uint256 id, uint32 a) external {
        games[id].playerA.energy = a;
    }

    function queued(uint256 id, address who) external view returns (Order memory) {
        return orders[id][who];
    }

    function committed(uint256 id, address who) external view returns (bool) {
        return commitments[id][who].committed;
    }
}

contract MovementTest is GameTestBase {
    MovementHarness game;
    address a = makeAddr("a");
    address b = makeAddr("b");
    uint256 id;

    function setUp() public {
        game = new MovementHarness();
        vm.prank(a);
        id = game.createGame();
        vm.prank(b);
        game.joinGame(id);
    }

    function move(address who, uint8 dest) internal {
        plan(id, who, ActionType.Move, dest);
    }

    function closeRound() internal {
        play(game, id, a, b);
    }

    function test_MovePaysAndClearsWithoutRepeating() public {
        move(a, 1);
        closeRound();
        assertEq(game.getGame(id).fleetA.position, 1);
        assertEq(game.getGame(id).playerA.energy, 6);
        assertEq(game.getGame(id).playerB.energy, 7);
        assertEq(uint8(game.queued(id, a).action), 0);
        assertFalse(game.committed(id, a));
        closeRound();
        assertEq(game.getGame(id).fleetA.position, 1);
        assertEq(game.getGame(id).playerA.energy, 8);
    }

    function test_SameDestinationDestroysBothAndClears() public {
        game.position(id, 0, 2);
        move(a, 1);
        move(b, 1);
        closeRound();
        assertEq(game.getGame(id).fleetA.ships, 0);
        assertEq(game.getGame(id).fleetB.ships, 0);
        assertEq(game.getGame(id).fleetA.position, 0);
        assertEq(game.getGame(id).fleetB.position, 24);
        assertEq(game.getGame(id).playerA.energy, 6);
        assertEq(game.getGame(id).playerB.energy, 6);
        assertEq(uint8(game.queued(id, a).action), 0);
        assertEq(uint8(game.queued(id, b).action), 0);
        assertFalse(game.committed(id, a));
        assertFalse(game.committed(id, b));
    }

    function test_SwapDestroysBoth() public {
        game.position(id, 1, 2);
        move(a, 2);
        move(b, 1);
        closeRound();
        assertEq(game.getGame(id).fleetA.ships, 0);
        assertEq(game.getGame(id).fleetB.ships, 0);
        assertEq(game.getGame(id).playerA.energy, 6);
        assertEq(game.getGame(id).playerB.energy, 6);
    }

    function test_VacatedSectorAllowed() public {
        game.position(id, 1, 2);
        move(a, 2);
        move(b, 3);
        closeRound();
        assertEq(game.getGame(id).fleetA.position, 2);
        assertEq(game.getGame(id).fleetB.position, 3);
    }

    function test_AttackEqualFleetDestroysBoth() public {
        game.position(id, 1, 2);
        move(a, 2);
        closeRound();
        assertEq(game.getGame(id).fleetA.ships, 0);
        assertEq(game.getGame(id).fleetB.ships, 0);
        assertEq(game.getGame(id).playerA.energy, 6);
        assertEq(game.getGame(id).playerB.energy, 7);
    }

    function invalidMove(uint8 origin, uint8 dest) internal {
        game.position(id, origin, 24);
        move(a, dest);
        closeRound();
        assertEq(game.getGame(id).fleetA.position, origin);
        assertEq(game.getGame(id).playerA.energy, 7);
    }

    function test_StationaryBecomesHold() public {
        invalidMove(0, 0);
    }

    function test_OutOfBoundsBecomesHold() public {
        invalidMove(0, 25);
    }

    function test_RowWrapBecomesHold() public {
        invalidMove(4, 5);
    }

    function test_DiagonalBecomesHold() public {
        invalidMove(1, 7);
    }

    function test_JumpBecomesHold() public {
        invalidMove(0, 2);
    }

    function test_ObstacleBecomesHold() public {
        invalidMove(1, 6);
    }

    function test_EnemyBaseBecomesHold() public {
        invalidMove(23, 24);
    }

    function test_BCannotEnterEnemyBase() public {
        game.position(id, 23, 1);
        move(b, 0);
        closeRound();
        assertEq(game.getGame(id).fleetB.position, 1);
    }

    function test_NoEnergyBecomesHold() public {
        game.energy(id, 0);
        move(a, 1);
        closeRound();
        assertEq(game.getGame(id).fleetA.position, 0);
        assertEq(game.getGame(id).playerA.energy, 2);
    }
}
