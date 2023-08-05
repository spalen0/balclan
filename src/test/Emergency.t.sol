// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract EmergencyTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_emergencyWithdraw(
        uint256 _deposit,
        uint256 _withdraw
    ) public {
        // don't withdraw all, test for that is below
        _deposit = bound(_deposit, minFuzzAmount * 2, maxFuzzAmount);
        _withdraw = bound(_withdraw, minFuzzAmount, _deposit - minFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _deposit);

        // DONE: Implement logic so totalDebt is _amount and totalIdle = 0.
        checkStrategyTotals(strategy, _deposit, _deposit, 0);

        // simulate minimal earnings to avoid rounding error of 1 token
        skip(2 minutes);

        // shutdown strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        // withdraw some funds
        vm.prank(management);
        strategy.emergencyWithdraw(_withdraw);
        assertEq(
            asset.balanceOf(address(strategy)),
            _withdraw,
            "!emergencyWithdraw"
        );

        // User can pull his funds or max strategy funds
        uint256 limit = strategy.availableWithdrawLimit(user);
        uint256 maxRedeem = Math.min(limit, strategy.balanceOf(user));
        vm.prank(user);
        strategy.redeem(maxRedeem, user, user);

        // assert strategy is empty
        checkStrategyTotals(strategy, 0, 0, 0);
        assertGe(asset.balanceOf(user), _deposit, "!redeem");
    }

    function test_emergencyWithdrawAll(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        checkStrategyTotals(strategy, _amount, _amount, 0);

        // simulate minimal earnings to avoid rounding error of 1 token
        skip(2 minutes);

        // shutdown strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        vm.prank(management);
        strategy.emergencyWithdraw(type(uint256).max);
        assertGe(
            asset.balanceOf(address(strategy)),
            _amount,
            "!emergencyWithdrawAll"
        );
    }
}
