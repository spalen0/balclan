// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IUniswapV3Swapper} from "@periphery/swappers/interfaces/IUniswapV3Swapper.sol";

interface IStrategyInterface is IStrategy, IUniswapV3Swapper {
    function A_TOKEN() external view returns (address);

    function claimRewards() external view returns (bool);

    function setUniFees(address _token0, address _token1, uint24 _fee) external;
}
