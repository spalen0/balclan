// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";

contract DecimalsTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_convertToUsd() public {
        uint256 amount = 1e8; // 1 WBTC
        uint256 converted = strategy.convertTokenToUSD(
            amount,
            tokenAddrs["WBTC"]
        );
        console.log("converted: %s", converted);
        uint256 convertedUsd = converted / 1e18; // usd is 18 decimals
        assertLt(convertedUsd, 40_000, "WBTC should be less than $40k");
        assertGt(convertedUsd, 20_000, "WBTC should be more than $20k");
    }

    function test_convertToAsset() public {
        uint256 amount = 30_000 * 1e18; // 30k USD
        uint256 converted = strategy.convertUSDToToken(
            amount,
            tokenAddrs["WBTC"]
        );
        console.log("converted: %s", converted);
        uint256 convertedWbtc = converted / 1e8;
        assertEq(convertedWbtc, 1, "30k USDC should be 1 WBTC");
    }
}
