// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {GameTestBase} from "./GameTestBase.sol";
import {DarkSector, ActionType, Game} from "../src/DarkSector.sol";

contract CombatHarness is DarkSector {
    function fixture(uint256 id, uint8 pa, uint8 pb, uint8 sa, uint8 sb) external {
        games[id].fleetA.position = pa;
        games[id].fleetB.position = pb;
        games[id].fleetA.ships = sa;
        games[id].fleetB.ships = sb;
    }

    function energy(uint256 id, uint32 ea, uint32 eb) external {
        games[id].playerA.energy = ea;
        games[id].playerB.energy = eb;
    }

    function own(uint256 id, uint8 p, address owner) external {
        sectorOwners[id][p] = owner;
    }

    function calc(uint8 a, uint8 b, bool da, bool db) external pure returns (uint8, uint8) {
        return _calculateCombat(a, b, da, db);
    }
}

contract CombatTest is GameTestBase {
    CombatHarness g;
    address a = makeAddr("a");
    address b = makeAddr("b");
    uint256 id;

    function setUp() public {
        g = new CombatHarness();
        vm.prank(a);
        id = g.createGame();
        vm.prank(b);
        g.joinGame(id);
    }

    function act(address who, ActionType action, uint8 dest) internal {
        plan(id, who, action, dest);
    }

    function closeRound() internal {
        play(g, id, a, b);
    }

    function test_AttackerASurvivesAndDoesNotCapture() public {
        g.fixture(id, 1, 2, 3, 1);
        g.own(id, 2, b);
        act(a, ActionType.Move, 2);
        closeRound();
        Game memory s = g.getGame(id);
        assertEq(s.fleetA.ships, 2);
        assertEq(s.fleetA.position, 2);
        assertEq(s.fleetB.ships, 0);
        assertEq(s.fleetB.position, 24);
        assertEq(g.getSectorOwner(id, 2), b);
        assertEq(s.playerA.energy, 6);
        assertEq(s.playerB.energy, 8);
        assertEq(s.playerB.points, 1);
    }

    function test_AttackerBSurvivesAndUpdatesOwnPosition() public {
        g.fixture(id, 1, 2, 1, 3);
        act(b, ActionType.Move, 1);
        closeRound();
        assertEq(g.getGame(id).fleetB.ships, 2);
        assertEq(g.getGame(id).fleetB.position, 1);
        assertEq(g.getGame(id).fleetA.position, 0);
        assertEq(g.getGame(id).fleetA.ships, 0);
    }

    function test_DefenseMakesThreeAgainstTwoMutualDestruction() public {
        g.fixture(id, 1, 2, 3, 2);
        act(a, ActionType.Move, 2);
        act(b, ActionType.Defend, 0);
        closeRound();
        assertEq(g.getGame(id).fleetA.ships, 0);
        assertEq(g.getGame(id).fleetB.ships, 0);
        assertEq(g.getGame(id).playerA.energy, 6);
        assertEq(g.getGame(id).playerB.energy, 7);
    }

    function test_DefenderCanSurviveAndCapture() public {
        g.fixture(id, 1, 2, 1, 3);
        act(a, ActionType.Move, 2);
        act(b, ActionType.Capture, 0);
        closeRound();
        assertEq(g.getGame(id).fleetB.ships, 2);
        assertEq(g.getGame(id).fleetB.position, 2);
        assertEq(g.getSectorOwner(id, 2), b);
    }

    function test_SwapSurvivorRemainsAtOriginAndBothPay() public {
        g.fixture(id, 1, 2, 3, 1);
        act(a, ActionType.Move, 2);
        act(b, ActionType.Move, 1);
        closeRound();
        assertEq(g.getGame(id).fleetA.ships, 2);
        assertEq(g.getGame(id).fleetA.position, 1);
        assertEq(g.getGame(id).playerA.energy, 6);
        assertEq(g.getGame(id).playerB.energy, 6);
    }

    function test_BuildBothAtBases() public {
        act(a, ActionType.Build, 0);
        act(b, ActionType.Build, 0);
        closeRound();
        assertEq(g.getGame(id).fleetA.ships, 4);
        assertEq(g.getGame(id).fleetB.ships, 4);
        assertEq(g.getGame(id).playerA.energy, 4);
        assertEq(g.getGame(id).playerB.energy, 4);
    }

    function test_BBuildIndependentOfA() public {
        g.fixture(id, 1, 24, 3, 3);
        act(b, ActionType.Build, 0);
        closeRound();
        assertEq(g.getGame(id).fleetB.ships, 4);
    }

    function test_RebuildAfterActualDestruction() public {
        g.fixture(id, 1, 2, 3, 3);
        act(a, ActionType.Move, 2);
        closeRound();
        act(a, ActionType.Build, 0);
        act(b, ActionType.Build, 0);
        closeRound();
        assertEq(g.getGame(id).fleetA.ships, 1);
        assertEq(g.getGame(id).fleetB.ships, 1);
        assertEq(g.getGame(id).fleetA.position, 0);
        assertEq(g.getGame(id).fleetB.position, 24);
        assertEq(g.getGame(id).playerA.energy, 5);
        assertEq(g.getGame(id).playerB.energy, 6);
    }

    function test_BuildInsufficientEnergyAndMaxShipsBecomeHold() public {
        g.fixture(id, 0, 24, 3, 10);
        g.energy(id, 2, 5);
        act(a, ActionType.Build, 0);
        act(b, ActionType.Build, 0);
        closeRound();
        assertEq(g.getGame(id).fleetA.ships, 3);
        assertEq(g.getGame(id).fleetB.ships, 10);
        assertEq(g.getGame(id).playerA.energy, 4);
        assertEq(g.getGame(id).playerB.energy, 7);
    }

    function test_BuildAwayFromBaseBecomesHold() public {
        g.fixture(id, 1, 23, 3, 3);
        act(a, ActionType.Build, 0);
        act(b, ActionType.Build, 0);
        closeRound();
        assertEq(g.getGame(id).fleetA.ships, 3);
        assertEq(g.getGame(id).playerA.energy, 7);
    }

    function test_DeadFleetCannotMoveCaptureOrDefend() public {
        g.fixture(id, 0, 24, 0, 0);
        act(a, ActionType.Move, 1);
        act(b, ActionType.Defend, 0);
        closeRound();
        assertEq(g.getGame(id).fleetA.position, 0);
        assertEq(g.getGame(id).playerA.energy, 7);
        act(a, ActionType.Capture, 0);
        closeRound();
        assertEq(g.getSectorOwner(id, 0), address(0));
    }

    function testFuzz_CombatMatchesRules(uint8 sa, uint8 sb, bool da, bool db) public view {
        sa = uint8(bound(sa, 1, 10));
        sb = uint8(bound(sb, 1, 10));
        (uint8 ra, uint8 rb) = g.calc(sa, sb, da, db);
        uint256 damageA = uint256(sb) + (db ? 1 : 0);
        uint256 damageB = uint256(sa) + (da ? 1 : 0);
        assertEq(ra, damageA >= sa ? 0 : sa - damageA);
        assertEq(rb, damageB >= sb ? 0 : sb - damageB);
        assertTrue(ra == 0 || rb == 0);
    }
}
