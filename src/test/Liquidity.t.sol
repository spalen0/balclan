// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";

contract LiquidityTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_aaveWithoutLiquidity() public {
        uint256 amount = maxFuzzAmount;
        mintAndDepositIntoStrategy(strategy, user, amount);

        // remove all liquidity from aave market
        address market = strategy.A_TOKEN();
        vm.startPrank(market);
        asset.transfer(address(0xdEaD), asset.balanceOf(address(market)));
        assertEq(
            asset.balanceOf(address(market)),
            0,
            "market should have 0 balance"
        );
        vm.stopPrank();

        // user should not be able to withdraw or record loss
        vm.prank(user);
        vm.expectRevert();
        strategy.redeem(amount / 2, user, user);

        // user won't loose funds if the aave is without liquidity
        assertEq(strategy.balanceOf(user), amount, "user lost funds");
    }
}
