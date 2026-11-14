// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {GameTestBase} from "./GameTestBase.sol";
import {DarkSector, ActionType, Game, GameResult, GameStatus, Order} from "../src/DarkSector.sol";

contract CaptureHarness is DarkSector {
    function place(uint256 id, uint8 a, uint8 b) external {
        games[id].fleetA.position = a;
        games[id].fleetB.position = b;
    }

    function own(uint256 id, uint8 p, address who) external {
        sectorOwners[id][p] = who;
    }

    function finalRound(uint256 id, uint32 a, uint32 b) external {
        games[id].round = 10;
        games[id].playerA.points = a;
        games[id].playerB.points = b;
    }

    function queued(uint256 id, address who) external view returns (Order memory) {
        return orders[id][who];
    }
}

contract CaptureTest is GameTestBase {
    CaptureHarness game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 id;
    event SectorCaptured(uint256 gameId, uint8 position, address indexed previousOwner, address indexed newOwner);
    event GameResultDeclared(uint256 indexed gameId, GameResult result, uint32 pointsA, uint32 pointsB);

    function setUp() public {
        game = new CaptureHarness();
        vm.prank(alice);
        id = game.createGame();
        vm.prank(bob);
        game.joinGame(id);
    }

    function closeRound() internal {
        play(game, id, alice, bob);
    }

    function prepareLastReveal() internal {
        Order memory oa = planned[id][alice];
        Order memory ob = planned[id][bob];
        bytes32 ha = commitment(game, id, alice, oa);
        bytes32 hb = commitment(game, id, bob, ob);
        vm.prank(alice);
        game.commitOrders(id, ha);
        vm.prank(bob);
        game.commitOrders(id, hb);
        vm.prank(alice);
        game.revealOrders(id, oa.action, oa.destination, SALT);
    }

    function lastReveal() internal {
        Order memory ob = planned[id][bob];
        vm.prank(bob);
        game.revealOrders(id, ob.action, ob.destination, SALT);
    }

    function capture(address who) internal {
        plan(id, who, ActionType.Capture, 255);
    }

    function test_InitialOwnersAndResult() public view {
        assertEq(game.getSectorOwner(id, 2), address(0));
        assertEq(game.getSectorOwner(id, 12), address(0));
        assertEq(uint8(game.getGame(id).result), uint8(GameResult.Pending));
        assertEq(game.getGame(id).playerA.points, 0);
    }

    function test_CaptureStationPaysImmediatelyAndIgnoresDestination() public {
        game.place(id, 2, 23);
        capture(alice);
        assertEq(game.getSectorOwner(id, 2), address(0));
        closeRound();
        Game memory g = game.getGame(id);
        assertEq(game.getSectorOwner(id, 2), alice);
        assertEq(g.fleetA.position, 2);
        assertEq(g.playerA.energy, 8);
        assertEq(g.playerA.points, 1);
        assertEq(g.playerB.energy, 7);

        assertEq(uint8(game.queued(id, alice).action), uint8(ActionType.Hold));
    }

    function test_CorePaysThreePointsAndOneEnergy() public {
        game.place(id, 12, 23);
        capture(alice);
        closeRound();
        assertEq(game.getGame(id).playerA.points, 3);
        assertEq(game.getGame(id).playerA.energy, 8);
    }

    function test_CaptureBaseBecomesHold() public {
        capture(alice);
        closeRound();
        assertEq(game.getSectorOwner(id, 0), address(0));
        assertEq(game.getGame(id).playerA.energy, 7);
    }

    function test_CaptureEmptyBecomesHold() public {
        game.place(id, 1, 23);
        capture(alice);
        closeRound();
        assertEq(game.getSectorOwner(id, 1), address(0));
        assertEq(game.getGame(id).playerA.points, 0);
    }

    function test_CaptureOwnSectorBecomesHold() public {
        game.place(id, 2, 23);
        game.own(id, 2, alice);
        capture(alice);
        closeRound();
        assertEq(game.getSectorOwner(id, 2), alice);
        assertEq(game.getGame(id).playerA.points, 1);
    }

    function test_ControlPersistsAfterLeaving() public {
        game.place(id, 2, 23);
        capture(alice);
        closeRound();
        plan(id, alice, ActionType.Move, 3);
        closeRound();
        assertEq(game.getSectorOwner(id, 2), alice);
        assertEq(game.getGame(id).playerA.points, 2);
        assertEq(game.getGame(id).playerA.energy, 10);
    }

    function test_EnemyRecaptureTransfersIncomeAndEmitsCorrectPosition() public {
        game.place(id, 3, 2);
        game.own(id, 2, alice);
        capture(bob);
        prepareLastReveal();
        vm.expectEmit(true, true, false, true, address(game));
        emit SectorCaptured(id, 2, alice, bob);
        lastReveal();
        assertEq(game.getSectorOwner(id, 2), bob);
        assertEq(game.getGame(id).playerA.points, 0);
        assertEq(game.getGame(id).playerB.points, 1);
    }

    function test_DestroyedCapturingFleetDoesNotCapture() public {
        game.place(id, 2, 3);
        capture(alice);
        plan(id, bob, ActionType.Move, 2);
        closeRound();
        assertEq(game.getGame(id).fleetA.ships, 0);
        assertEq(game.getGame(id).fleetB.ships, 0);
        assertEq(game.getGame(id).playerB.energy, 6);
        assertEq(game.getSectorOwner(id, 2), address(0));
    }

    function test_MultipleTerritoriesAccumulateIncome() public {
        game.place(id, 1, 23);
        game.own(id, 2, alice);
        game.own(id, 10, alice);
        game.own(id, 12, alice);
        closeRound();
        assertEq(game.getGame(id).playerA.energy, 10);
        assertEq(game.getGame(id).playerA.points, 5);
    }

    function test_FinalRoundCaptureCountsBeforeWinnerAndEvent() public {
        game.place(id, 2, 23);
        game.finalRound(id, 0, 0);
        capture(alice);
        prepareLastReveal();
        vm.expectEmit(true, false, false, true, address(game));
        emit GameResultDeclared(id, GameResult.PlayerAWins, 1, 0);
        lastReveal();
        assertEq(uint8(game.getGame(id).result), uint8(GameResult.PlayerAWins));
        assertEq(uint8(game.getGame(id).status), uint8(GameStatus.Finished));
        assertEq(game.getGame(id).round, 10);
    }

    function test_BWinsOnPoints() public {
        game.finalRound(id, 1, 2);
        closeRound();
        assertEq(uint8(game.getGame(id).result), uint8(GameResult.PlayerBWins));
    }

    function test_TieBreakStationsA() public {
        game.own(id, 2, alice);
        game.finalRound(id, 0, 1);
        closeRound();
        assertEq(uint8(game.getGame(id).result), uint8(GameResult.PlayerAWins));
    }

    function test_TieBreakStationsB() public {
        game.own(id, 2, bob);
        game.finalRound(id, 1, 0);
        closeRound();
        assertEq(uint8(game.getGame(id).result), uint8(GameResult.PlayerBWins));
    }

    function test_CoreDoesNotCountForTieBreak() public {
        game.own(id, 12, alice);
        game.own(id, 2, bob);
        game.finalRound(id, 0, 2);
        closeRound();
        assertEq(game.getGame(id).playerA.points, 3);
        assertEq(game.getGame(id).playerB.points, 3);
        assertEq(uint8(game.getGame(id).result), uint8(GameResult.PlayerBWins));
    }

    function test_ExactTieDraws() public {
        game.finalRound(id, 3, 3);
        closeRound();
        assertEq(uint8(game.getGame(id).result), uint8(GameResult.Draw));
    }

    function test_OwnerLookupRejectsInvalidGameAndPosition() public {
        vm.expectRevert();
        game.getSectorOwner(999, 2);
        vm.expectRevert();
        game.getSectorOwner(id, 25);
    }

    function test_IndependentOwnership() public {
        game.own(id, 2, alice);
        vm.prank(alice);
        uint256 other = game.createGame();
        vm.prank(bob);
        game.joinGame(other);
        assertEq(game.getSectorOwner(other, 2), address(0));
    }

    function test_RealPathCaptureAndLeave() public {
        plan(id, alice, ActionType.Move, 1);
        closeRound();
        assertEq(game.getGame(id).playerA.energy, 6);
        plan(id, alice, ActionType.Move, 2);
        closeRound();
        assertEq(game.getGame(id).playerA.energy, 7);
        capture(alice);
        closeRound();
        assertEq(game.getGame(id).playerA.energy, 10);
        plan(id, alice, ActionType.Move, 3);
        closeRound();
        assertEq(game.getGame(id).playerA.energy, 12);
        assertEq(game.getGame(id).playerA.points, 2);
    }
}
