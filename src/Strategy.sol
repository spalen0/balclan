// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {BaseTokenizedStrategy} from "@tokenized-strategy/BaseTokenizedStrategy.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IAToken} from "./interfaces/Aave/V3/IAtoken.sol";
import {IPoolAddressesProvider} from "./interfaces/Aave/V3/IPoolAddressesProvider.sol";
import {IPool, DataTypesV3} from "./interfaces/Aave/V3/IPool.sol";
import {IPriceOracleGetter} from "./interfaces/Aave/V3/IPriceOracleGetter.sol";
import {IReserveInterestRateStrategy} from "./interfaces/Aave/V3/IReserveInterestRateStrategy.sol";
import {IProtocolDataProvider} from "./interfaces/Aave/V3/IProtocolDataProvider.sol";

import {IComet} from "./interfaces/Compound/IComet.sol";
import {ICometRewards} from "./interfaces/Compound/ICometRewards.sol";

// import "forge-std/console.sol";

contract Strategy is BaseTokenizedStrategy, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    address public immutable borrowAsset;
    IAToken public immutable borrowAToken;
    IAToken public immutable aToken;
    // IERC20Metadata public constant borrowDebtToken =
    //     IERC20Metadata(0xFCCf3cAbbe80101232d343252614b6A3eE81C989); // for test
    IPool public immutable aaveLendingPool;
    IPriceOracleGetter public immutable aavePriceOracle;
    IProtocolDataProvider public immutable aaveProtocolDataProvider;
    /// @notice The interest rate strategy contract for the borrow asset.
    IReserveInterestRateStrategy public immutable supplyInterestRate;
    /// @notice The interest rate strategy contract for the borrow asset.
    IReserveInterestRateStrategy public immutable borrowInterestRate;
    IComet public immutable comet;
    ICometRewards public immutable cometRewards;
    uint256 public immutable cometBaseMantissa;
    uint256 public immutable cometBaseIndexScale;

    uint256 internal constant AAVE_PRICE_ORACLE_BASE = 1e8;
    uint256 internal constant RATE_MODE = 2; // 2 = Stable, 1 = Variable
    uint16 internal constant REF_CODE = 0; // 0 = No referral code
    uint256 internal constant LTV_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000; // prettier-ignore
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant SECONDS_PER_DAY = 24 hours;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant DAYS_PER_YEAR = 365;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant WAD_RAY_RATIO = 1e9;
    // @todo think about changing to variable to allow setting by yChad
    address internal constant COMP_PRICE_FEED =
        0x2A8758b7257102461BC958279054e372C2b1bDE6; // https://data.chain.link/polygon/mainnet/crypto-usd/comp-usd

    /// @notice value in basis points(BPS) max value is 10_000
    uint256 public ltvTarget;
    uint256 public lowerLtv;
    uint256 public upperLtv;

    uint256 public supplyDust = 1e3;

    uint256 public mode = 0; // 0 --> supply/borrow AAVE, supply Compound, 1 --> supply/borrow Compound, supply AAVE

    constructor(
        address _asset,
        string memory _name,
        address _borrowAsset,
        address _aavePoolDataProvider,
        address _comet,
        address _cometRewards
    ) BaseTokenizedStrategy(_asset, _name) {
        IPoolAddressesProvider aavePoolDataProvider = IPoolAddressesProvider(
            _aavePoolDataProvider
        );
        aaveLendingPool = IPool(aavePoolDataProvider.getPool());
        require(address(aaveLendingPool) != address(0), "!aaveLendingPool");
        aavePriceOracle = IPriceOracleGetter(
            aavePoolDataProvider.getPriceOracle()
        );
        require(address(aavePriceOracle) != address(0), "!aavePriceOracle");

        // Set the aToken based on the asset we are using.
        DataTypesV3.ReserveData memory supplyConfig = aaveLendingPool
            .getReserveData(_asset);
        aToken = IAToken(supplyConfig.aTokenAddress);

        DataTypesV3.ReserveData memory borrowConfig = aaveLendingPool
            .getReserveData(_borrowAsset);
        borrowAToken = IAToken(borrowConfig.aTokenAddress);
        borrowInterestRate = IReserveInterestRateStrategy(
            borrowConfig.interestRateStrategyAddress
        );
        supplyInterestRate = IReserveInterestRateStrategy(
            borrowConfig.interestRateStrategyAddress
        );

        require(address(aToken) != address(0), "!aToken");
        require(address(borrowAToken) != address(0), "!borrowAToken");
        require(
            address(borrowInterestRate) != address(0),
            "!borrowInterestRate"
        );

        aaveProtocolDataProvider = IProtocolDataProvider(
            aavePoolDataProvider.getPoolDataProvider()
        );
        require(
            address(aaveProtocolDataProvider.ADDRESSES_PROVIDER()) ==
                _aavePoolDataProvider,
            "!_aavePoolDataProvider"
        );

        // compound check
        comet = IComet(_comet);
        require(comet.baseToken() == _borrowAsset, "!baseToken");
        ERC20(_borrowAsset).safeApprove(_comet, type(uint256).max);
        ERC20(asset).safeApprove(_comet, type(uint256).max);
        cometBaseMantissa = comet.baseScale();
        cometBaseIndexScale = comet.trackingIndexScale(); // @todo verify trackingIndexScale is used instead of baseIndexScale
        require(cometBaseMantissa > 0, "!cometBaseMantissa");
        require(cometBaseIndexScale > 0, "!cometBaseIndexScale");

        cometRewards = ICometRewards(_cometRewards);
        address compToken = cometRewards.rewardConfig(_comet).token;
        require(compToken != address(0), "!compToken");

        borrowAsset = _borrowAsset;
        ltvTarget = 50_00; // 50%
        lowerLtv = 40_00; // 40%
        upperLtv = 60_00; // 60%

        // Make approve the lending pool for cheaper deposits.
        ERC20(_asset).safeApprove(address(aaveLendingPool), type(uint256).max);
        ERC20(_borrowAsset).safeApprove(
            address(aaveLendingPool),
            type(uint256).max
        );

        minAmountToSell = 1e17; // COMP ~ $57
        base = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619; // WETH
        router = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // UNI V3 Router
        ERC20(compToken).safeApprove(router, type(uint256).max);
        _setUniFees(compToken, base, 3000);
        _setUniFees(base, asset, 500);

        require(
            IERC20Metadata(_borrowAsset).decimals() < 19,
            "_borrowAsset.decimals>18"
        );
        require(IERC20Metadata(_asset).decimals() < 19, "_asset.decimals>18");
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
    function setLtvTarget(uint256 _ltvTarget) external onlyManagement {
        // @todo verfiy it's below defined max collateral target in aave
        DataTypesV3.ReserveConfigurationMap memory data = aaveLendingPool
            .getConfiguration(asset);
        // from aave library: https://github.com/aave/aave-v3-core/blob/27a6d5c83560694210849d4abf09a09dec8da388/contracts/protocol/libraries/configuration/ReserveConfiguration.sol#L85
        uint256 maxLtv = data.data & ~LTV_MASK;
        require(_ltvTarget < maxLtv, "!ltvTarget");
        ltvTarget = _ltvTarget;
    }

    /// @notice set lower bound for rebalance
    /// @param _lowerLtv lower bound for rebalance in BPS
    function setLowerLtv(uint256 _lowerLtv) external onlyManagement {
        require(_lowerLtv < ltvTarget, "!lowerLtv");
        lowerLtv = _lowerLtv;
    }

    /// @notice set upper bound for rebalance
    /// @param _upperLtv upper bound for rebalance in BPS
    function setUpperLtv(uint256 _upperLtv) external onlyManagement {
        require(_upperLtv > ltvTarget, "!upperLtv");
        upperLtv = _upperLtv;
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
        // Supply aave, borrow USDC aave, supply USDC Compound

        // supply regardless, we always supply
        // borrow or repay if needed
        if (mode == 0) {
            _aaveSupply(_amount, asset);
            _rebalanceMode0();
        } else {
            _compSupply(_amount, asset);
            _rebalanceMode1();
        }
    }

    function _rebalanceMode0() internal {
        // both 18 decimals
        (uint256 supply, uint256 borrow) = _aaveSupplyBorrowBalancesInUSD();

        if (supply < supplyDust) return;

        // current ltv, including our supply
        uint256 currentLTV = _getLTV(supply, borrow);

        // desired borrows given target ltv
        uint256 desiredBorrows = _getBorrowFromSupply(supply, ltvTarget);

        // we need to deleverage, a.k.a repay
        if (currentLTV > upperLtv) {
            // withdraw up to desired so we can repay
            uint256 toWithdraw = borrow - desiredBorrows; // this is USD terms with 18 decimals

            // in terms of USDC, 6 decimals
            toWithdraw = convertUSDToToken(toWithdraw, borrowAsset);

            // withdraw from compound
            _compWithdraw(toWithdraw, borrowAsset);

            // repay aave
            _aaveRepay(toWithdraw);
        }

        // we need to leverage, a.k.a borrow
        if (currentLTV < lowerLtv) {
            // borrow up to desired so we can leverage
            uint256 toBorrow = desiredBorrows - borrow;

            // in terms of USDC, 6 decimals
            toBorrow = convertUSDToToken(toBorrow, borrowAsset);

            // borrow aave
            _aaveBorrow(toBorrow);

            // supply compound
            _compSupply(toBorrow, borrowAsset);
        }
    }

    function _rebalanceMode1() internal {
        // both 18 decimals, in terms of USD
        uint256 supply = _compCollateralBalanceInUSD(asset);
        uint256 borrow = _compBorrowedFundsInUSD();

        // current ltv, including our supply
        uint256 currentLTV = _getLTV(supply, borrow);

        // desired borrows given target ltv
        uint256 desiredBorrows = _getBorrowFromSupply(supply, ltvTarget);

        // we need to deleverage, a.k.a repay
        if (currentLTV > upperLtv) {
            // withdraw up to desired so we can repay
            uint256 toWithdraw = borrow - desiredBorrows;

            // 6 decimals
            toWithdraw = convertUSDToToken(toWithdraw, borrowAsset);

            // withdraw from aave
            _aaveWithdraw(toWithdraw, borrowAsset);

            // repay comp
            _compSupply(toWithdraw, borrowAsset);
        }

        // we need to leverage, a.k.a borrow
        if (currentLTV < lowerLtv) {
            // borrow up to desired so we can leverage
            uint256 toBorrow = desiredBorrows - borrow;

            // 6 decimals
            toBorrow = convertUSDToToken(toBorrow, borrowAsset);

            // borrow compound
            _compWithdraw(toBorrow, borrowAsset);

            // supply aave
            _aaveSupply(toBorrow, borrowAsset);
        }
    }

    function _getSupplyFromBorrow(
        uint256 borrow,
        uint256 targetLTV
    ) internal pure returns (uint256) {
        // borrow / supply = ltv

        // borrow / ltv = supply
        return (borrow * MAX_BPS) / targetLTV;
    }

    function _getBorrowFromSupply(
        uint256 supply,
        uint256 targetLTV
    ) internal pure returns (uint256) {
        // borrow / supply = ltv

        // supply * ltv = borrow
        return (supply * targetLTV) / MAX_BPS;
    }

    function _getLTV(
        uint256 supply,
        uint256 borrow
    ) internal pure returns (uint256) {
        return (borrow * MAX_BPS) / supply;
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
        uint256 amountInUSDC = _convertAssetToBorrow(_amount);

        // 0 --> supply/borrow AAVE, supply Compound
        if (mode == 0) {
            // we should revert if we cannot withdraw sepcified amount
            // we can withdraw from compound up to whatever we have supplied
            amountInUSDC = Math.min(_compSuppliedFundsInUSDC(), amountInUSDC);

            // withdraw the necessary or all the USDC from Compound
            _compWithdraw(amountInUSDC, borrowAsset);

            // repay the necessary or all the USDC from Compound
            // if strategy is healthy we should end up 0 debt in the AAVE here
            // _aaveRepay(
            //     Math.min(amountInUSDC, borrowDebtToken.balanceOf(address(this)))
            // );
            _aaveRepay(amountInUSDC);

            // withdraw the requested amount from the aave
            // we should revert if we cannot withdraw sepcified amount
            _aaveWithdraw(_amount, asset);

            // rebalance if needed
            _rebalanceMode0();

            // 1 --> supply/borrow Compound, supply AAVE
        } else {
            // we can withdraw from aave up to whatever we have supplied
            amountInUSDC = Math.min(
                borrowAToken.balanceOf(address(this)),
                amountInUSDC
            );

            // withdraw the necessary or all the USDC from aave
            _aaveWithdraw(amountInUSDC, borrowAsset);

            // repay the necessary or all the USDC from aave
            // if strategy is healthy we should end up 0 debt in the compound here
            _compSupply(amountInUSDC, borrowAsset);

            // withdraw the requested amount from the compound
            _compWithdraw(_amount, asset);

            // rebalance if needed
            _rebalanceMode1();
        }
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
            _claimAndSellRewards();
            uint256 idleAssets = ERC20(asset).balanceOf(address(this));
            // deploy idle, also rebalances
            if (idleAssets != 0) _deployFunds(idleAssets);
        }

        // we have supply & borrow in AAVE and supply in Compound
        uint256 usdBalanceCompSupplied = _compSuppliedFundsInUSD();
        uint256 usdBalanceCompBorrowed = _compBorrowedFundsInUSD();
        (
            uint256 usdBalanceAaveSupplied,
            uint256 usdBalanceAaveBorrowed
        ) = _aaveSupplyBorrowBalancesInUSD();

        // all supply is + and all borrow is -
        _totalAssets =
            usdBalanceCompSupplied +
            usdBalanceAaveSupplied -
            usdBalanceCompBorrowed -
            usdBalanceAaveBorrowed;

        // convert lending balance in asset token
        _totalAssets = convertUSDToToken(_totalAssets, asset);

        // total assets in asset token
        _totalAssets = _totalAssets + ERC20(asset).balanceOf(address(this));
    }

    // @todo set to internal and remove return value
    function _claimAndSellRewards() public returns (uint256) {
        cometRewards.claim(address(comet), address(this), true);
        address comp = cometRewards.rewardConfig(address(comet)).token;
        uint256 balance = ERC20(comp).balanceOf(address(this));
        return _swapFrom(comp, asset, balance, 0);
    }

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
            (, uint256 debt, , , , ) = aaveLendingPool.getUserAccountData(
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
        // _flowAaveCompRepay(_totalIdle);
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
        (uint256 collateral, uint256 debt, , , , ) = aaveLendingPool
            .getUserAccountData(address(this));
        if (collateral > 0 && debt > 0) {
            uint256 ltv = (debt * MAX_BPS) / collateral;
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
        // return
        // 	TokenizedStrategy.totalIdle() + ERC20(asset).balanceOf(address(aToken));

        return type(uint256).max;
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
        if (mode == 0) {
            // @todo scale to max comp liquidity
            _compWithdraw(type(uint256).max, borrowAsset);
            _aaveRepay(type(uint256).max);

            uint256 aaveMax = Math.min(
                ERC20(asset).balanceOf(address(aToken)),
                aToken.balanceOf(address(this))
            );

            // withdraw as much as possible from aave
            // slither-disable-next-line unused-return
            aaveLendingPool.withdraw(
                asset,
                Math.min(_amount, aaveMax),
                address(this)
            );
        } else {
            uint256 aaveMax = Math.min(
                ERC20(borrowAsset).balanceOf(address(borrowAToken)),
                borrowAToken.balanceOf(address(this))
            );
            _aaveWithdraw(aaveMax, borrowAsset);

            _compSupply(
                ERC20(borrowAsset).balanceOf(address(this)),
                borrowAsset
            );

            // @todo scale down to max comp liquidity
            _compWithdraw(type(uint256).max, asset);
        }
    }

    // --- AAVE HELPERS --- //

    /// @dev repay debt to aave in borrowAsset must be reaculated
    /// @param _amount amount to repay in borrowAsset
    function _aaveRepay(uint256 _amount) private {
        // @todo maybe remove param and just use all free balance
        // _amount = borrowDebtToken.balanceOf(address(this));
        aaveLendingPool.repay(borrowAsset, _amount, RATE_MODE, address(this));
    }

    function _aaveSupply(uint256 _amount, address _asset) private {
        aaveLendingPool.supply(_asset, _amount, address(this), REF_CODE);
    }

    function _aaveWithdraw(uint256 amount, address token) private {
        aaveLendingPool.withdraw(token, amount, address(this));
    }

    function _aaveBorrow(uint256 amount) private {
        aaveLendingPool.borrow(
            borrowAsset,
            amount,
            RATE_MODE,
            REF_CODE,
            address(this)
        );
    }

    /// @dev calcualte interest rates for borrowAsset for supplied/removed amount
    /// @param _amount amount in borrowAsset
    /// @return supplyRate supply rate
    /// @return borrowRate borrow rate
    // @note can use uint and bool for add/remove
    function aaveRates(
        int256 _amount
    ) public view returns (uint256 supplyRate, uint256 borrowRate) {
        (
            uint256 unbacked,
            ,
            ,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            ,
            ,
            ,
            uint256 averageStableBorrowRate,
            ,
            ,

        ) = aaveProtocolDataProvider.getReserveData(borrowAsset);

        (, , , , uint256 reserveFactor, , , , , ) = aaveProtocolDataProvider
            .getReserveConfigurationData(borrowAsset);

        uint256 liquidityAdded;
        uint256 liquidityTaken;
        if (_amount > 0) {
            liquidityAdded = uint256(_amount);
        } else {
            liquidityTaken = uint256(-_amount);
        }

        DataTypesV3.CalculateInterestRatesParams memory params = DataTypesV3
            .CalculateInterestRatesParams(
                unbacked,
                liquidityAdded,
                liquidityTaken,
                totalStableDebt,
                totalVariableDebt,
                averageStableBorrowRate,
                reserveFactor,
                borrowAsset,
                address(borrowAToken)
            );
        (supplyRate, , borrowRate) = supplyInterestRate.calculateInterestRates(
            params
        );
        supplyRate = supplyRate / WAD_RAY_RATIO;
        borrowRate = borrowRate / WAD_RAY_RATIO;
    }

    /// @dev calculate new ltv after supplying
    /// @param _amount amount in asset
    /// @return new ltv after supplying _amount
    function _aaveNewLtvSupply(
        uint256 _amount
    ) internal view returns (uint256) {
        (uint256 collateral, uint256 debt, , , , ) = aaveLendingPool
            .getUserAccountData(address(this));
        uint256 price = aavePriceOracle.getAssetPrice(asset);
        collateral += _amount * price;
        return (debt * MAX_BPS) / collateral;
    }

    /// @dev calculate new ltv after borrowing
    /// @param _amount amount in asset
    /// @return ltv after borrowing _amount
    function _aaveNewLtvBorrow(
        uint256 _amount
    ) internal view returns (uint256) {
        (uint256 collateral, uint256 debt, , , , ) = aaveLendingPool
            .getUserAccountData(address(this));
        // cannot borrow without collateral
        if (collateral == 0) {
            return MAX_BPS;
        }
        uint256 price = aavePriceOracle.getAssetPrice(asset);
        debt += _amount * price;
        return (debt * MAX_BPS) / collateral;
    }

    /// @dev Get current possition in aave, collateral - debt in asset value
    /// @return funds in asset value
    function aaveFunds() public view returns (uint256) {
        (uint256 collateral, uint256 debt, , , , ) = aaveLendingPool
            .getUserAccountData(address(this));
        uint256 price = aavePriceOracle.getAssetPrice(asset);
        return
            ((collateral - debt) * 10 ** TokenizedStrategy.decimals()) / price;
    }

    /// @dev 18 decimals in terms of USD
    function _aaveSupplyBorrowBalancesInUSD()
        internal
        view
        returns (uint256 supply, uint256 borrow)
    {
        (supply, borrow, , , , ) = aaveLendingPool.getUserAccountData(
            address(this)
        );

        // 1e18 = AAVE_PRICE_ORACLE_BASE(1e8) * 1e10
        supply = supply * 1e10;
        borrow = borrow * 1e10;
    }

    // --- COMPOUND HELPERS --- //

    /// @dev supply borrowAsset to compound
    /// @param _amount amount to supply in borrowAsset
    function _compSupply(uint256 _amount, address token) internal {
        if (!comet.isSupplyPaused()) {
            comet.supply(token, _amount);
        }
    }

    /// @dev withdraw borrowAsset from compound
    /// @param _amount amount to withdraw in borrowAsset
    function _compWithdraw(
        uint256 _amount,
        address token
    ) internal returns (uint256) {
        // _amount = Math.min(_amount, comet.balanceOf(address(this)));
        comet.withdraw(token, _amount);
        return _amount;
    }

    /// @dev USDC supplied to compound
    /// @return funds in asset value (USD)
    function _compSuppliedFundsInUSD() internal view returns (uint256) {
        uint256 suppliedBalance = comet.balanceOf(address(this)); // 6 decimals, in terms of usdc
        return convertTokenToUSD(suppliedBalance, borrowAsset); // 18 decimals, in terms of USD
    }

    /// @dev USDC borrowed from compound
    /// @return funds in asset value (USD)
    function _compBorrowedFundsInUSD() internal view returns (uint256) {
        uint256 borrowedBalance = comet.borrowBalanceOf(address(this)); // 6 decimals, in terms of usdc
        return convertTokenToUSD(borrowedBalance, borrowAsset);
    }

    /// @dev Collateral supplied tp compound
    /// @return funds in asset value (USD)
    function _compCollateralBalanceInUSD(
        address collateral
    ) internal view returns (uint256) {
        IComet.UserCollateral memory c = comet.userCollateral(
            address(this),
            collateral
        ); // collateral decimals

        return convertTokenToUSD(c.balance, collateral);
    }

    /// @dev asset supplied to compound
    /// @return funds in asset value
    function _compSuppliedFundsInUSDC() public view returns (uint256) {
        return comet.balanceOf(address(this));
    }

    /// @dev caluclate supply rate for borrowAsset for given amount
    /// @param _amount amount in borrowAsset to supply to compound
    /// @return supply rate in WAD
    function compSupplyRate(int256 _amount) public view returns (uint256) {
        uint256 borrows = comet.totalBorrow();
        uint256 supply = comet.totalSupply();
        uint256 utiliaztion = (borrows * WAD) /
            uint256(int256(supply) + _amount);
        uint256 supplyRate = comet.getSupplyRate(utiliaztion) *
            SECONDS_PER_YEAR;

        return supplyRate + _compRewardForSupplyBase(_amount);
    }

    /// @dev caluclate borrow rate for borrowAsset for given amount
    /// @param _amount amount in borrowAsset to borrow from compound
    /// @return borrow rate in WAD
    function compBorrowRate(int256 _amount) public view returns (uint256) {
        uint256 borrows = comet.totalBorrow();
        uint256 supply = comet.totalSupply();
        uint256 utiliaztion = (uint256(int256(borrows) + _amount) * WAD) /
            supply;
        uint256 borrowRate = comet.getBorrowRate(utiliaztion) *
            SECONDS_PER_YEAR;
        uint256 rewardsRate = _compRewardForBorrowBase(_amount);

        if (borrowRate > rewardsRate) {
            // remove base reward because rewards are paying for borrow
            return borrowRate - rewardsRate;
        }
        // we are earning from borrowing
    }

    function _compRewardForSupplyBase(
        int256 _amount
    ) internal view returns (uint256) {
        uint256 rewardToSuppliersPerDay = (comet.baseTrackingSupplySpeed() *
            SECONDS_PER_DAY *
            cometBaseIndexScale) / cometBaseMantissa;
        if (rewardToSuppliersPerDay == 0) return 0;

        uint256 rewardTokenPriceInUsd = _compPrice(COMP_PRICE_FEED);
        uint256 assetPriceInUsd = _compPrice(comet.baseTokenPriceFeed());
        uint256 assetTotalSupply = uint256(
            int256(comet.totalSupply()) + _amount
        );
        return
            ((rewardTokenPriceInUsd * rewardToSuppliersPerDay) /
                (assetTotalSupply * assetPriceInUsd)) * DAYS_PER_YEAR;
    }

    function _compRewardForBorrowBase(
        int256 _amoount
    ) internal view returns (uint256) {
        uint256 rewardToBowwersPerDay = (comet.baseTrackingBorrowSpeed() *
            SECONDS_PER_DAY *
            cometBaseIndexScale) / cometBaseMantissa;
        if (rewardToBowwersPerDay == 0) return 0;

        uint256 rewardTokenPriceInUsd = _compPrice(COMP_PRICE_FEED);
        uint256 assetPriceInUsd = _compPrice(comet.baseTokenPriceFeed());
        uint256 assetTotalBorrow = uint256(
            int256(comet.totalBorrow()) + _amoount
        );
        return
            ((rewardTokenPriceInUsd * rewardToBowwersPerDay) /
                (assetTotalBorrow * assetPriceInUsd)) * DAYS_PER_YEAR;
    }

    /// @dev get price of asset from compound
    /// @param singleAssetPriceFeed price feed address for wanted asset
    /// @return price of asset in USD
    function _compPrice(
        address singleAssetPriceFeed
    ) internal view returns (uint256) {
        return comet.getPrice(singleAssetPriceFeed);
    }

    /// @dev convert borrowAsset to asset, use aave oracle to get price
    /// both comp and aave use chainlink oracle as main oracle
    /// @param _amount amount of borrowAsset to convert to asset
    function _convertBorrowToAsset(
        uint256 _amount
    ) internal view returns (uint256) {
        uint256 assetPrice = aavePriceOracle.getAssetPrice(asset);
        uint256 borrowPrice = aavePriceOracle.getAssetPrice(borrowAsset);
        // @todo defined flow for 0, maybe revert?
        // wbtc = 8 decimasl / usdc = 6 decimals -> * 1e2 to get the same amount
        return (_amount * borrowPrice * 10 ** 2) / assetPrice;
    }

    /// @dev convert asset to borrowAsset, use aave oracle to get price
    /// both comp and aave use chainlink oracle as main oracle
    /// @param _amount amount of asset to convert to borrowAsset
    function _convertAssetToBorrow(
        uint256 _amount
    ) internal view returns (uint256) {
        uint256 assetPrice = aavePriceOracle.getAssetPrice(asset);
        uint256 borrowPrice = aavePriceOracle.getAssetPrice(borrowAsset);
        // @todo extract decimals for borrowAsset,
        // wbtc = 8 decimasl / usdc = 6 decimals -> / 1e2 to get the same amount
        return (_amount * assetPrice) / borrowPrice / 10 ** 2;
    }

    /// @dev _amount is always in 18 decimals and its denominated in USD
    /// returns always the tokens native decimals
    function convertUSDToToken(
        uint256 _amount,
        address _token
    ) public view returns (uint256) {
        if (_amount == 0) return 0;
        uint256 tokenPrice = aavePriceOracle.getAssetPrice(_token); // price in 8 decimals always
        uint256 tokenDecimals = IERC20Metadata(_token).decimals();

        return
            (_amount * AAVE_PRICE_ORACLE_BASE) /
            tokenPrice /
            10 ** (18 - tokenDecimals);
    }

    /// @dev _amount is always in tokens native decimals
    /// returns always the 18 decimaled USD value
    function convertTokenToUSD(
        uint256 _amount,
        address _token
    ) public view returns (uint256) {
        if (_amount == 0) return 0;
        uint256 tokenPrice = aavePriceOracle.getAssetPrice(_token); // price in 8 decimals always
        uint256 tokenDecimals = IERC20Metadata(_token).decimals();

        return
            (_amount * 10 ** (18 - tokenDecimals) * tokenPrice) /
            AAVE_PRICE_ORACLE_BASE;
    }
}
