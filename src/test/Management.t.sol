// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";

contract ManagementTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function testSetUniFees() public {
        vm.prank(user);
        vm.expectRevert("!Authorized");
        strategy.setUniFees(address(1), address(2), 500);

        // management can setUniFees
        vm.prank(management);
        strategy.setUniFees(address(1), address(2), 500);
    }
}
