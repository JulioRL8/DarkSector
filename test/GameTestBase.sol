// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {Test} from "forge-std/Test.sol";
import {DarkSector, ActionType, Order} from "../src/DarkSector.sol";

abstract contract GameTestBase is Test {
    bytes32 internal constant SALT = keccak256("test fixture salt");
    mapping(uint256 => mapping(address => Order)) internal planned;

    function plan(uint256 id, address who, ActionType action, uint8 dest) internal {
        planned[id][who] = Order(action, dest);
    }

    function commitment(DarkSector g, uint256 id, address who, Order memory o) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(address(g), block.chainid, id, g.getGame(id).round, who, o.action, o.destination, SALT)
            );
    }

    function play(DarkSector g, uint256 id, address a, address b) internal {
        Order memory oa = planned[id][a];
        Order memory ob = planned[id][b];
        bytes32 ha = commitment(g, id, a, oa);
        bytes32 hb = commitment(g, id, b, ob);
        vm.prank(a);
        g.commitOrders(id, ha);
        vm.prank(b);
        g.commitOrders(id, hb);
        vm.prank(a);
        g.revealOrders(id, oa.action, oa.destination, SALT);
        vm.prank(b);
        g.revealOrders(id, ob.action, ob.destination, SALT);
        delete planned[id][a];
        delete planned[id][b];
    }
}
