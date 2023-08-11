// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IUniswapV3Swapper} from "@periphery/swappers/interfaces/IUniswapV3Swapper.sol";

interface IStrategyInterface is IStrategy, IUniswapV3Swapper {
    function aToken() external view returns (address);

    function claimRewards() external view returns (bool);

    function setUniFees(address _token0, address _token1, uint24 _fee) external;

    function minAmountToSell() external view returns (uint256);

    function setMinAmountToSell(uint256 _minAmountToSell) external;

    function ltvTarget() external view returns (uint256);

    function setLtvTarget(uint256 _ltvTarget) external;

    function lowerLtv() external view returns (uint256);

    function setLowerLtv(uint256 _lowerLtv) external;

    function upperLtv() external view returns (uint256);

    function setUpperLtv(uint256 _upperLtv) external;

    function aaveRates(int256 _amount) external view returns (uint256, uint256);

    function compSupplyRate(int _amount) external view returns (uint256);

    function compBorrowRate(int _amount) external view returns (uint256);

    function convertTokenToUSD(
        uint256 _amount,
        address _token
    ) external view returns (uint256);

    function convertUSDToToken(
        uint256 _amount,
        address _token
    ) external view returns (uint256);

    // @todo remove after testing
    function _claimAndSellRewards() external returns (uint256);
}
