// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";

contract AprChangeTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_checkAaveAprChange(uint256 _amount, uint16 _percentChange) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _percentChange = uint16(bound(uint256(_percentChange), 10, MAX_BPS));

        // TODO: adjust the number to base _perfenctChange off of.
        uint256 _delta = (_amount * _percentChange) / MAX_BPS;

        (uint256 currentAprSupply, uint256 currentApyBorrow) = strategy.aaveRates(0);
        console.log("currentAprSupply: %s", currentAprSupply);
        console.log("currentApyBorrow: %s", currentApyBorrow);

        // Should be greater than 0 but likely less than 100%
        assertGt(currentAprSupply, 0, "ZERO");
        assertLt(currentAprSupply, 1e18, "+100%");
        assertGt(currentApyBorrow, 0, "ZERO");
        assertLt(currentApyBorrow, 1e18, "+100%");

        (uint256 negativeAprSupply, uint256 negativeApyBorrow) = strategy.aaveRates(-int256(_delta));
        // The apr should go up if deposits go down
        assertLt(currentAprSupply, negativeAprSupply, "negative supply change");
        assertLt(currentApyBorrow, negativeApyBorrow, "negative borrow change");

        (uint256 possitveAprSupply, uint256 positiveApyBorrow) = strategy.aaveRates(int256(_delta));
        assertGt(currentAprSupply, possitveAprSupply, "positive supply change");
        assertGt(currentApyBorrow, positiveApyBorrow, "positive borrow change");
    }

    function test_checkCompoundAprChange(
        uint256 _amount,
        uint16 _percentChange
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _percentChange = uint16(bound(uint256(_percentChange), 50, MAX_BPS));

        uint256 _delta = (_amount * _percentChange) / MAX_BPS;

        uint256 currentApSupply = strategy.compSupplyRate(0);
        uint256 currentAprBorrow = strategy.compBorrowRate(0);
        console.log("current apr supply: %s", currentApSupply);
        console.log("current apr borrow: %s", currentAprBorrow);

        // Should be greater than 0 but likely less than 100%
        assertGt(currentApSupply, 0, "ZERO");
        assertLt(currentApSupply, 1e18, "+100%");
        assertGt(currentAprBorrow, 0, "ZERO");
        assertLt(currentAprBorrow, 1e18, "+100%");

        uint256 negativeAprSupply = strategy.compSupplyRate(-int256(_delta));
        uint256 negativeAprBorrow = strategy.compBorrowRate(-int256(_delta));
        assertLt(currentApSupply, negativeAprSupply, "negative supply change");
        // @todo verify borrow change
        // assertGt(currentAprBorrow, negativeAprBorrow, "negative borrow change");

        uint256 possitveAprSupply = strategy.compSupplyRate(int256(_delta));
        uint256 positiveAprBorrow = strategy.compBorrowRate(int256(_delta));
        assertGt(currentApSupply, possitveAprSupply, "positive supply change");
        // @todo verify borrow change
        // assertLt(currentAprBorrow, positiveAprBorrow, "positive borrow change");
    }
}
