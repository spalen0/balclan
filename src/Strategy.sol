// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {BaseTokenizedStrategy} from "@tokenized-strategy/BaseTokenizedStrategy.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

import {IAToken} from "./interfaces/Aave/V3/IAtoken.sol";
import {IPool, DataTypesV3} from "./interfaces/Aave/V3/IPool.sol";
import {IPriceOracleGetter} from "./interfaces/Aave/V3/IPriceOracleGetter.sol";

contract Strategy is BaseTokenizedStrategy, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    address public immutable borrowAsset;
    IAToken public immutable aToken;

    IPool internal constant AAVE_LENDING_POOL =
        IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IPriceOracleGetter internal constant AAVE_PRICE_ORACLE =
        IPriceOracleGetter(0xb023e699F5a33916Ea823A16485e259257cA8Bd1);
    uint256 internal constant RATE_MODE = 2; // 2 = Stable, 1 = Variable
    uint16 internal constant REF_CODE = 0; // 0 = No referral code
    uint256 internal constant LTV_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000; // prettier-ignore
    uint256 internal constant MAX_BPS = 10_000;
    /// @notice value in basis points(BPS) max value is 10_000
    uint256 public ltvTarget;

    constructor(
        address _asset,
        string memory _name,
        address _borrowAsset
    ) BaseTokenizedStrategy(_asset, _name) {
        // Set the aToken based on the asset we are using.
        aToken = IAToken(
            AAVE_LENDING_POOL.getReserveData(_asset).aTokenAddress
        );
        IAToken borrowAToken = IAToken(
            AAVE_LENDING_POOL.getReserveData(_borrowAsset).aTokenAddress
        );

        // Make sure its a real token.
        require(address(aToken) != address(0), "!aToken");
        require(address(borrowAToken) != address(0), "!borrowAToken");
        borrowAsset = _borrowAsset;

        ltvTarget = 50_00; // 50%

        // Make approve the lending pool for cheaper deposits.
        ERC20(_asset).safeApprove(
            address(AAVE_LENDING_POOL),
            type(uint256).max
        );
        ERC20(_borrowAsset).safeApprove(address(AAVE_LENDING_POOL), type(uint256).max);

        minAmountToSell = 1e17; // COMP ~ $57
        base = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619; // WETH
        router = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // UNI V3 Router
    }

    /**
     * @notice Set the uni fees for swaps.
     * @dev External function available to management to set
     * the fees used in the `UniswapV3Swapper.
     *
     * Any incentived tokens will need a fee to be set for each
     * reward token that it wishes to swap on reports.
     *
     * @param _token0 The first token of the pair.
     * @param _token1 The second token of the pair.
     * @param _fee The fee to be used for the pair.
     */
    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        _setUniFees(_token0, _token1, _fee);
    }

    /**
     * @notice Set the min amount to sell.
     * @dev External function available to management to set
     * the `minAmountToSell` variable in the `UniswapV3Swapper`.
     *
     * @param _minAmountToSell The min amount of tokens to sell.
     */
    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        minAmountToSell = _minAmountToSell;
    }

    /**
     * @notice Set the ltv target.
     * @dev External function available to management to set
     * the `ltvTarget` variable. 
     *
     * @param _ltvTarget The ltv target. Max value must be lower than
     * the max value for asset config in aave.
     */
    function setLtvTarget(
        uint256 _ltvTarget
    ) external onlyManagement {
        // @todo verfiy it's below defined max collateral target in aave
        DataTypesV3.ReserveConfigurationMap memory data = AAVE_LENDING_POOL.getConfiguration(asset);
        // from aave library: https://github.com/aave/aave-v3-core/blob/27a6d5c83560694210849d4abf09a09dec8da388/contracts/protocol/libraries/configuration/ReserveConfiguration.sol#L85
        uint256 maxLtv = data.data & ~LTV_MASK;
        require(_ltvTarget < maxLtv, "!ltvTarget");
        ltvTarget = _ltvTarget;
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permsionless and thus can be sandwhiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attemppt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        AAVE_LENDING_POOL.supply(asset, _amount, address(this), REF_CODE);

        // @note only for testing: Borrow half of the deposited amount.
        AAVE_LENDING_POOL.borrow(borrowAsset, _amount, RATE_MODE, REF_CODE, address(this));
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permsionless and thus can be sandwhiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting puroposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // scale down amount to max available
        _amount = Math.min(aToken.balanceOf(address(this)), _amount);

        // borrowing is the same for ltv as withdrawing
        uint256 newLtv = _aaveNewLtvBorrow(_amount);
        if (newLtv > ltvTarget) {
            // repay debt if withdraw would put us over target
            _aaveRepay(_amount);
        }

        uint256 withdrawn = AAVE_LENDING_POOL.withdraw(
            asset,
            _amount,
            address(this)
        );
        // verify we didn't lose funds in aave
        require(withdrawn >= _amount, "!freeFunds");
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        if (!TokenizedStrategy.isShutdown()) {
            // Claim and sell any rewards to `asset`.
            // _claimAndSellRewards();

            // deposit any loose funds
            uint256 looseAsset = ERC20(asset).balanceOf(address(this));
            if (looseAsset > 0) {
                AAVE_LENDING_POOL.supply(asset, looseAsset, address(this), REF_CODE);
                // @todo implement whole flow, not just borrow
                AAVE_LENDING_POOL.borrow(borrowAsset, looseAsset, RATE_MODE, REF_CODE, address(this));
            }
        }

        // total is in our collateral not borrowed asset
        // @todo calculate loss from borrow, use aave oracle
        _totalAssets =
            aToken.balanceOf(address(this)) +
            ERC20(asset).balanceOf(address(this));
    }

    // @todo implement
    // function _claimAndSellRewards() internal {
    //claim all rewards
    // _swapFrom(token, asset, balance, 0);
    // }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a persionned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed poisition maintence or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwhiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * The TokenizedStrategy contract will do all needed debt and idle updates
     * after this has finished and will have no effect on PPS of the strategy
     * till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    */
    function _tend(uint256 _totalIdle) internal override {
        // tend is used for repaying debt
        // check if the idle amount is not enoguh for repay
        if (_aaveNewLtvSupply(_totalIdle) > ltvTarget) {
            // use _totalIdle instead of debt
            (, uint256 debt, , , , ) = AAVE_LENDING_POOL.getUserAccountData(
                address(this)
            );
            // set new value to max possible
            debt = debt / 2;
            for (uint256 i; i < 4; ++i) {
                if (_aaveNewLtvSupply(_totalIdle) < ltvTarget) {
                    // we found value to repay
                    break;
                }
                // if we didn't find value to repay, set to half
                debt = debt / 2;
            }
            _totalIdle = debt;
        }
        // repay debt
        _aaveRepay(_totalIdle);
    }

    /**
     * @notice Returns wether or not tend() should be called by a keeper.
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    */
    function tendTrigger() public view override returns (bool) {
        // tend is used for repaying debt
        (uint256 collateral, uint256 debt, , , , ) = AAVE_LENDING_POOL.getUserAccountData(
            address(this)
        );
        if (collateral > 0 && debt > 0) {
            uint256 ltv = debt * MAX_BPS / collateral;
            if (ltv > ltvTarget) {
                return true;
            }
        }
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overriden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwhichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The avialable amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return
            TokenizedStrategy.totalIdle() +
            ERC20(asset).balanceOf(address(aToken));
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A seperate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // reapy all
        _aaveRepay(type(uint256).max);

        uint256 aaveMax = Math.min(
            ERC20(asset).balanceOf(address(aToken)),
            aToken.balanceOf(address(this))
        );

        // withdraw as much as possible from aave
        // slither-disable-next-line unused-return
        AAVE_LENDING_POOL.withdraw(
            asset,
            Math.min(_amount, aaveMax),
            address(this)
        );
    }

    // --- AAVE HELPERS --- //

    /// @dev repay debt to aave in borrow asset must be reaculated
    /// @param _amount amount to repay in borrow asset
    function _aaveRepay(uint256 _amount) internal {
        (uint256 collateral, uint256 debt, , , , ) = AAVE_LENDING_POOL.getUserAccountData(
            address(this)
        );
        if (debt > 0) {
            // @todo check how ot 
            // debt = Math.min(debt, _amount);
            // @note aave reverts if you try to repay 0 debt
            AAVE_LENDING_POOL.repay(borrowAsset, debt, RATE_MODE, address(this));
        }
    }

    function _aaveBorrowRate() internal view returns (uint256) {
        return AAVE_LENDING_POOL.getReserveData(borrowAsset).currentVariableBorrowRate;
    }

    function _aaveSupplyRate() internal view returns (uint256) {
        return AAVE_LENDING_POOL.getReserveData(asset).currentLiquidityRate;
    }

    /// @dev calculate new ltv after supplying
    /// @param _amount amount to supply
    /// @return new ltv after supplying _amount
    function _aaveNewLtvSupply(uint256 _amount) internal view returns (uint256) {
        (uint256 collateral, uint256 debt, , , , ) = AAVE_LENDING_POOL.getUserAccountData(
            address(this)
        );
        uint256 price = AAVE_PRICE_ORACLE.getAssetPrice(asset);
        collateral += _amount * price;
        return debt * MAX_BPS / collateral;
    }

    /// @dev calculate new ltv after borrowing
    /// @param _amount amount of debt to in asset
    /// @return ltv after borrowing _amount
    function _aaveNewLtvBorrow(uint256 _amount) internal view returns (uint256) {
        (uint256 collateral, uint256 debt, , , , ) = AAVE_LENDING_POOL.getUserAccountData(
            address(this)
        );
        uint256 price = AAVE_PRICE_ORACLE.getAssetPrice(asset);
        debt += _amount * price;
        return debt * MAX_BPS / collateral;
    }
}
