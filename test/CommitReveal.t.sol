// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {Test} from "forge-std/Test.sol";
import {CaptureHarness} from "./Capture.t.sol";
import {ActionType, RoundPhase, GameStatus} from "../src/DarkSector.sol";

contract CommitRevealTest is Test {
    CaptureHarness game;
    address a = makeAddr("a");
    address b = makeAddr("b");
    uint256 id;
    bytes32 salt = keccak256("test-only salt");

    function setUp() public {
        game = new CaptureHarness();
        vm.prank(a);
        id = game.createGame();
        vm.prank(b);
        game.joinGame(id);
    }

    function hash(address who, ActionType action, uint8 dest) internal view returns (bytes32) {
        return keccak256(abi.encode(address(game), block.chainid, id, game.getGame(id).round, who, action, dest, salt));
    }

    function commitBoth(ActionType action, uint8 dest) internal {
        bytes32 ha = hash(a, action, dest);
        bytes32 hb = hash(b, ActionType.Hold, 0);
        vm.prank(a);
        game.commitOrders(id, ha);
        vm.prank(b);
        game.commitOrders(id, hb);
    }

    function revealBoth(ActionType action, uint8 dest) internal {
        vm.prank(a);
        game.revealOrders(id, action, dest, salt);
        vm.prank(b);
        game.revealOrders(id, ActionType.Hold, 0, salt);
    }

    function test_RevealAdvancesRoundAndResetsPhase() public {
        commitBoth(ActionType.Move, 1);
        revealBoth(ActionType.Move, 1);
        assertEq(game.getGame(id).fleetA.position, 1);
        assertEq(game.getGame(id).round, 2, "Round must advance");
        assertEq(uint8(game.getGame(id).phase), uint8(RoundPhase.Commit));
    }

    function test_ValidCaptureSurvivesReveal() public {
        game.place(id, 2, 23);
        commitBoth(ActionType.Capture, 0);
        revealBoth(ActionType.Capture, 0);
        assertEq(game.getSectorOwner(id, 2), a);
    }

    function test_RevealedOrderCannotBeOverwrittenThroughOldAPI() public {
        commitBoth(ActionType.Move, 1);
        vm.prank(a);
        game.revealOrders(id, ActionType.Move, 1, salt);
        vm.prank(a);
        // Legacy entry point must be disabled in the new protocol.
        (bool ok,) = address(game)
            .call(abi.encodeWithSignature("submitOrder(uint256,uint8,uint8)", id, uint8(ActionType.Move), uint8(5)));
        assertFalse(ok);
    }

    function test_JoinStartsFreshDeadline() public {
        vm.prank(a);
        uint256 other = game.createGame();
        vm.warp(block.timestamp + 301);
        vm.prank(b);
        game.joinGame(other);
        assertGt(game.getGame(other).phaseDeadline, block.timestamp);
    }

    function test_CannotCommitBeforeGameStarts() public {
        vm.prank(a);
        uint256 other = game.createGame();
        vm.prank(a);
        vm.expectRevert();
        game.commitOrders(other, bytes32(uint256(1)));
    }

    function test_WrongSaltRejectedAndCorrectRevealCanRetry() public {
        commitBoth(ActionType.Move, 1);
        vm.prank(a);
        vm.expectRevert();
        game.revealOrders(id, ActionType.Move, 1, bytes32(0));
        revealBoth(ActionType.Move, 1);
        assertEq(game.getGame(id).fleetA.position, 1);
    }

    function test_InvalidMoveBecomesHold() public {
        commitBoth(ActionType.Move, 25);
        revealBoth(ActionType.Move, 25);
        assertEq(game.getGame(id).fleetA.position, 0);
        assertEq(game.getGame(id).playerA.energy, 7);
    }

    function test_DuplicateCommitRejected() public {
        bytes32 h = hash(a, ActionType.Hold, 0);
        vm.prank(a);
        game.commitOrders(id, h);
        vm.prank(a);
        vm.expectRevert();
        game.commitOrders(id, h);
    }

    function test_OutsiderCommitRejected() public {
        vm.prank(address(999));
        vm.expectRevert();
        game.commitOrders(id, bytes32(0));
    }

    function test_RevealBeforeBothCommitRejected() public {
        bytes32 h = hash(a, ActionType.Hold, 0);
        vm.prank(a);
        game.commitOrders(id, h);
        vm.prank(a);
        vm.expectRevert();
        game.revealOrders(id, ActionType.Hold, 0, salt);
    }

    function test_FirstRevealDoesNotExecuteAndDuplicateRejected() public {
        commitBoth(ActionType.Move, 1);
        vm.prank(a);
        game.revealOrders(id, ActionType.Move, 1, salt);
        assertEq(game.getGame(id).fleetA.position, 0);
        assertEq(game.getGame(id).playerA.energy, 5);
        vm.prank(a);
        vm.expectRevert();
        game.revealOrders(id, ActionType.Move, 1, salt);
    }

    function test_DifferentActionCannotReplaceCommitment() public {
        commitBoth(ActionType.Move, 1);
        vm.prank(a);
        vm.expectRevert();
        game.revealOrders(id, ActionType.Move, 5, salt);
    }

    function test_CommitAtDeadlineRejected() public {
        bytes32 h = hash(a, ActionType.Hold, 0);
        vm.warp(game.getGame(id).phaseDeadline);
        vm.prank(a);
        vm.expectRevert();
        game.commitOrders(id, h);
    }

    function test_RevealAtDeadlineRejected() public {
        commitBoth(ActionType.Hold, 0);
        vm.warp(game.getGame(id).phaseDeadline);
        vm.prank(a);
        vm.expectRevert();
        game.revealOrders(id, ActionType.Hold, 0, salt);
    }

    function test_OldRoundCommitmentCannotReplay() public {
        bytes32 oldHash = hash(a, ActionType.Hold, 0);
        commitBoth(ActionType.Hold, 0);
        revealBoth(ActionType.Hold, 0);
        bytes32 hb = hash(b, ActionType.Hold, 0);
        vm.prank(a);
        game.commitOrders(id, oldHash);
        vm.prank(b);
        game.commitOrders(id, hb);
        vm.prank(a);
        vm.expectRevert();
        game.revealOrders(id, ActionType.Hold, 0, salt);
    }
}
