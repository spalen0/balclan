// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";

contract ManagementTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_setUniFees() public {
        vm.prank(user);
        vm.expectRevert("!Authorized");
        strategy.setUniFees(address(1), address(2), 500);

        // management can setUniFees
        vm.prank(management);
        strategy.setUniFees(address(1), address(2), 500);
    }

    function test_setMinAmountToSell() public {
        vm.prank(user);
        vm.expectRevert("!Authorized");
        strategy.setMinAmountToSell(1);

        // management can setUniFees
        vm.prank(management);
        strategy.setMinAmountToSell(1);
        assertEq(strategy.minAmountToSell(), 1);
    }

    function test_setLtvTarget() public {
        vm.prank(user);
        vm.expectRevert("!Authorized");
        strategy.setLtvTarget(1);

        // management can setLtvTarget
        vm.prank(management);
        vm.expectRevert("!ltvTarget");
        strategy.setLtvTarget(9_999);

        vm.prank(management);
        strategy.setLtvTarget(11);
        assertEq(strategy.ltvTarget(), 11);
    }
}
