pragma solidity ^0.8.13;
import {Test} from "forge-std/Test.sol";
import {DarkSector, ActionType, RoundPhase, GameResult, GameStatus} from "../src/DarkSector.sol";

contract TimeoutTest is Test {
    DarkSector g;
    address a = address(10);
    address b = address(20);
    uint256 id;
    bytes32 salt = bytes32(uint256(123));

    function setUp() public {
        g = new DarkSector();
        vm.prank(a);
        id = g.createGame();
        vm.prank(b);
        g.joinGame(id);
    }

    function commit(address p, ActionType action, uint8 d) internal {
        bytes32 h = keccak256(abi.encode(address(g), block.chainid, id, g.getGame(id).round, p, action, d, salt));
        vm.prank(p);
        g.commitOrders(id, h);
    }

    function reveal(address p, ActionType action, uint8 d) internal {
        vm.prank(p);
        g.revealOrders(id, action, d, salt);
    }

    function expire() internal {
        vm.warp(g.getGame(id).phaseDeadline);
        g.advanceAfterTimeout(id);
    }

    function test_NoCommitsAdvancesOnceAndCannotRepeat() public {
        expire();
        assertEq(g.getGame(id).round, 2);
        assertEq(g.getGame(id).playerA.energy, 7);
        vm.expectRevert();
        g.advanceAfterTimeout(id);
    }

    function test_OnlyOneCommitCanRevealAndFinishWithoutFaults() public {
        commit(a, ActionType.Move, 1);
        expire();
        assertEq(uint8(g.getGame(id).phase), uint8(RoundPhase.Reveal));
        reveal(a, ActionType.Move, 1);
        assertEq(g.getGame(id).round, 2);
        assertEq(g.getGame(id).fleetA.position, 1);
        assertEq(g.revealFaults(id, b), 0);
    }

    function test_SecondFaultLosesWithoutExecutingOrIncome() public {
        commit(a, ActionType.Hold, 0);
        commit(b, ActionType.Hold, 0);
        reveal(a, ActionType.Hold, 0);
        expire();
        assertEq(g.revealFaults(id, b), 1);
        assertEq(g.getGame(id).round, 2);
        commit(a, ActionType.Move, 1);
        commit(b, ActionType.Hold, 0);
        reveal(a, ActionType.Move, 1);
        expire();
        assertEq(uint8(g.getGame(id).result), uint8(GameResult.PlayerAWins));
        assertEq(uint8(g.getGame(id).status), uint8(GameStatus.Finished));
        assertEq(g.getGame(id).fleetA.position, 0);
        assertEq(g.getGame(id).playerA.energy, 7);
        vm.expectRevert();
        g.advanceAfterTimeout(id);
    }

    function test_BothSecondFaultDraws() public {
        for (uint256 i; i < 2; i++) {
            commit(a, ActionType.Hold, 0);
            commit(b, ActionType.Hold, 0);
            expire();
        }
        assertEq(uint8(g.getGame(id).result), uint8(GameResult.Draw));
        assertEq(g.getGame(id).playerA.energy, 7);
    }

    function test_TenRoundsNormalReveal() public {
        for (uint256 i; i < 10; i++) {
            commit(a, ActionType.Hold, 0);
            commit(b, ActionType.Hold, 0);
            reveal(a, ActionType.Hold, 0);
            reveal(b, ActionType.Hold, 0);
        }
        assertEq(uint8(g.getGame(id).status), uint8(GameStatus.Finished));
        assertEq(g.getGame(id).round, 10);
        assertEq(g.getGame(id).playerA.energy, 25);
    }

    function test_TenRoundsNoCommits() public {
        for (uint256 i; i < 10; i++) {
            expire();
        }
        assertEq(uint8(g.getGame(id).result), uint8(GameResult.Draw));
        assertEq(g.getGame(id).playerA.energy, 25);
    }
}
