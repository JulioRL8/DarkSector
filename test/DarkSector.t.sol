// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {GameTestBase} from "./GameTestBase.sol";
import {
    DarkSector,
    Game,
    GameStatus,
    GameResult,
    RoundPhase,
    SectorType,
    Order,
    ActionType
} from "../src/DarkSector.sol";

contract DarkSectorTest is GameTestBase {
    DarkSector game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    event GameCreated(uint256 indexed gameId, address indexed creator);
    event GameStarted(uint256 indexed gameId, address indexed playerA, address indexed playerB);

    function setUp() public {
        game = new DarkSector();
    }

    function create() internal returns (uint256 id) {
        vm.prank(alice);
        id = game.createGame();
    }

    function start() internal returns (uint256 id) {
        id = create();
        vm.prank(bob);
        game.joinGame(id);
    }

    function test_CreateAndUniqueIds() public {
        vm.expectEmit(true, true, false, true, address(game));
        emit GameCreated(0, alice);
        uint256 id = create();
        Game memory g = game.getGame(id);
        assertEq(g.playerA.account, alice);
        assertEq(g.playerB.account, address(0));
        assertEq(uint8(g.status), uint8(GameStatus.WaitingForPlayer));
        assertNotEq(id, create());
    }

    function test_JoinAndInitialState() public {
        uint256 id = create();
        vm.expectEmit(true, true, true, true, address(game));
        emit GameStarted(id, alice, bob);
        vm.prank(bob);
        game.joinGame(id);
        Game memory g = game.getGame(id);
        assertEq(g.playerB.account, bob);
        assertEq(uint8(g.status), uint8(GameStatus.Active));
        assertEq(g.round, 1);
        assertEq(g.playerA.energy, 5);
        assertEq(g.playerB.energy, 5);
        assertEq(g.fleetA.position, 0);
        assertEq(g.fleetB.position, 24);
        assertEq(g.fleetA.ships, 3);
        assertEq(g.fleetB.ships, 3);
        assertEq(uint8(g.phase), uint8(RoundPhase.Commit));
    }

    function test_RejectSelfJoinAndThirdPlayer() public {
        uint256 id = create();
        vm.prank(alice);
        vm.expectRevert(DarkSector.InvalidAddress.selector);
        game.joinGame(id);
        vm.prank(bob);
        game.joinGame(id);
        vm.expectRevert();
        game.joinGame(id);
    }

    function test_CompleteTenRoundsAndIncome() public {
        uint256 id = start();
        for (uint8 r = 1; r <= 10; r++) {
            assertEq(game.getGame(id).round, r);
            play(game, id, alice, bob);
        }
        Game memory g = game.getGame(id);
        assertEq(g.round, 10);
        assertEq(uint8(g.status), uint8(GameStatus.Finished));
        assertEq(uint8(g.result), uint8(GameResult.Draw));
        assertEq(g.playerA.energy, 25);
        assertEq(g.playerB.energy, 25);
        vm.prank(alice);
        vm.expectRevert();
        game.commitOrders(id, bytes32(uint256(1)));
    }

    function test_GamesIndependent() public {
        uint256 a = start();
        uint256 b = start();
        play(game, a, alice, bob);
        assertEq(game.getGame(a).round, 2);
        assertEq(game.getGame(b).round, 1);
        assertEq(game.getGame(b).playerA.energy, 5);
    }

    function test_UnknownGameRejected() public {
        vm.expectRevert();
        game.getGame(999);
        vm.expectRevert();
        game.joinGame(999);
        vm.expectRevert();
        game.commitOrders(999, bytes32(0));
        vm.expectRevert();
        game.revealOrders(999, ActionType.Hold, 0, SALT);
    }

    function test_MapMatchesLayoutAndBounds() public {
        uint256 id = start();
        for (uint8 p; p < 25; p++) {
            SectorType expected = SectorType.Empty;
            if (p == 0 || p == 24) expected = SectorType.Base;
            else if (p == 12) expected = SectorType.CentralCore;
            else if (p == 2 || p == 10 || p == 14 || p == 22) expected = SectorType.EnergyStation;
            else if (p == 6 || p == 8 || p == 16 || p == 18) expected = SectorType.Obstacle;
            assertEq(uint8(game.getSectorType(p, id)), uint8(expected));
        }
        vm.expectRevert();
        game.getSectorType(25, id);
    }
}
