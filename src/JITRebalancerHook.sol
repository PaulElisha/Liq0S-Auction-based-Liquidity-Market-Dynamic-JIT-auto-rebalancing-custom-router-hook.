// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/Hooks.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/Pool.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/types/BalanceDelta.sol";
import "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import "v4-periphery/src/utils/BaseHook.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./libraries/TrySwap.sol";
import "./libraries/TickExtended.sol";
import "./libraries/PoolExtended.sol";

contract JITRebalancerHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SwapMath for uint160;
    using TickMath for uint160;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolExtended for *;
    using TickExtended for *;
    using TrySwap for IPoolManager;

    mapping(PoolId poolId => PoolExtended.Info info) public poolInfo;
    mapping(PoolId poolId => PoolKey key) public pools;
    mapping(PoolId poolId => Bid[]) public bids;

    uint256 public constant THRESHOLD = 100; // 1% threshold in Basis Points Scale

    struct Bid {
        address bidderAddress;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    event BidRegistered(
        address indexed bidder,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    );

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (this.afterAddLiquidity.selector, delta);
        }

        address sender = abi.decode(hookData, (address));

        if (sender == address(0)) {
            return (this.afterAddLiquidity.selector, delta);
        }

        {
            _registerLPBid(sender, key, params);
        }

        return (this.afterAddLiquidity.selector, delta);
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        require(
            _arePoolKeysEqual(pools[key.toId()], key),
            "pool key not found"
        );

        {
            poolInfo.update(poolId, poolManager);
        }

        uint160 sqrtPriceX96;
        uint128 liquidity;

        {
            (sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
            liquidity = poolManager.getLiquidity(poolId);
        }

        int256 swapAmount = _abs(swapParams);

        bool islargeSwap;

        {
            islargeSwap = _isLargeSwap(liquidity, sqrtPriceX96, swapAmount);
        }

        BeforeSwapDelta deltas;
        if (islargeSwap) {
            deltas = _executeLargeSwap(poolId, key, swapParams);
        }

        return (this.beforeSwap.selector, deltas, 0);
    }

    function _executeLargeSwap(
        PoolId poolId,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams
    ) internal returns (BeforeSwapDelta) {
        BalanceDelta result = poolManager.swap(
            poolId,
            Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: swapParams.zeroForOne,
                amountSpecified: swapParams.amountSpecified,
                sqrtPriceLimitX96: swapParams.sqrtPriceLimitX96,
                lpFeeOverride: 0
            }),
            swapStepHook
        );

        return toBeforeSwapDelta(result.amount0(), result.amount1());
    }

    function swapStepHook(
        PoolId poolId,
        Pool.StepComputations memory step,
        Pool.SwapResult memory state
    ) internal {
        PoolKey memory key = pools[poolId];

        if (state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized) {
            {
                poolInfo[poolId].ticks.cross(
                    step.tickNext,
                    poolInfo[poolId].secondsPerLiquidityGlobalX128
                );
            }

            int24 tickLower;
            int24 tickUpper;

            {
                (tickLower, tickUpper) = _getUsableTicks(
                    step.sqrtPriceNextX96,
                    key.tickSpacing
                );
            }

            Bid memory winningBid;
            BalanceDelta delta;

            {
                winningBid = _selectWinningBid(poolId);
                require(
                    winningBid.bidderAddress != address(0),
                    "No valid bids"
                );
            }

            {
                delta = _removeLiquidity(key, winningBid);
            }

            {
                _addLiquidity(
                    key,
                    tickLower,
                    tickUpper,
                    delta,
                    state,
                    winningBid
                );
            }
        }
    }

    function _getUsableTicks(
        uint160 sqrtPriceNextX96,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        tickLower = _closestUsableTick(sqrtPriceNextX96, tickSpacing, false);
        tickUpper = _closestUsableTick(sqrtPriceNextX96, tickSpacing, true);
    }

    function _removeLiquidity(
        PoolKey memory key,
        Bid memory winningBid
    ) internal returns (BalanceDelta delta) {
        {
            (delta, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: winningBid.tickLower,
                    tickUpper: winningBid.tickUpper,
                    liquidityDelta: -int256(winningBid.liquidityDelta),
                    salt: 0
                }),
                hex""
            );

            _handleBalanceAccounting(delta, address(this), key);
        }
    }

    function _addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        BalanceDelta _delta,
        Pool.SwapResult memory state,
        Bid memory winningBid
    ) internal {
        uint128 liquidityDelta;
        {
            liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                state.sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                uint256(int256(_delta.amount0())),
                uint256(int256(_delta.amount1()))
            );
        }

        winningBid.tickLower = tickLower;
        winningBid.tickUpper = tickUpper;
        winningBid.liquidityDelta = int256(uint256(liquidityDelta));

        {
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: winningBid.liquidityDelta,
                    salt: 0
                }),
                hex""
            );

            _handleBalanceAccounting(delta, address(this), key);
        }
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata data
    ) internal override onlyPoolManager returns (bytes4, int128) {
        Bid memory winningBid = _selectWinningBid(key.toId());

        (BalanceDelta _delta, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: winningBid.tickLower,
                tickUpper: winningBid.tickUpper,
                liquidityDelta: -int128(winningBid.liquidityDelta),
                salt: 0
            }),
            data
        );

        _handleBalanceAccounting(_delta, winningBid.bidderAddress, key);

        // @dev: delete the pool from the mapping
        delete bids[key.toId()];

        return (this.afterSwap.selector, 0);
    }

    function _registerLPBid(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params
    ) internal {
        PoolId poolId = key.toId();

        if (!_arePoolKeysEqual(pools[poolId], key)) {
            pools[poolId] = key;
        }

        require(params.tickLower < params.tickUpper, "Invalid ticks");

        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        uint256 minLiquidity = (uint256(poolLiquidity) * THRESHOLD) / 10000;

        require(
            uint256(params.liquidityDelta) >= minLiquidity,
            "Insufficient liquidity for large swaps"
        );

        bids[poolId].push(
            Bid({
                bidderAddress: sender,
                poolId: poolId,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta
            })
        );

        emit BidRegistered(
            sender,
            poolId,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta
        );
    }

    function getBids(PoolId poolId) external view returns (Bid[] memory) {
        return bids[poolId];
    }

    function _selectWinningBid(
        PoolId poolId
    ) internal returns (Bid memory winningBid) {
        Bid[] storage poolBids = bids[poolId];
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        uint256 minLiquidityForLargeSwap = (uint256(poolLiquidity) *
            THRESHOLD) / 10000;

        // @dev: cache the following parameters
        uint256 winningBidIndex = 0;
        int256 maxBidLiquidity = 0;

        for (uint256 i = 0; i < poolBids.length; i++) {
            if (poolBids[i].liquidityDelta >= maxBidLiquidity) {
                winningBidIndex = i;
                maxBidLiquidity = poolBids[i].liquidityDelta;
            }
        }

        if (maxBidLiquidity >= int256(minLiquidityForLargeSwap)) {
            winningBid = poolBids[winningBidIndex];
            poolBids[winningBidIndex] = poolBids[poolBids.length - 1];
            poolBids.pop();
        }
    }

    function _handleBalanceAccounting(
        BalanceDelta delta,
        address recipient,
        PoolKey memory key
    ) internal {
        if (delta.amount0() > 0) {
            poolManager.take(
                key.currency0,
                recipient,
                uint128(delta.amount0())
            );
        } else if (delta.amount0() < 0) {
            _transferFromAndSettle(
                key.currency0,
                recipient,
                uint128(-delta.amount0())
            );
        }

        if (delta.amount1() > 0) {
            poolManager.take(
                key.currency1,
                recipient,
                uint128(delta.amount1())
            );
        } else if (delta.amount1() < 0) {
            _transferFromAndSettle(
                key.currency1,
                recipient,
                uint128(-delta.amount1())
            );
        }
    }

    function _transferFromAndSettle(
        Currency currency,
        address recipient,
        uint128 amount
    ) internal {
        IERC20(Currency.unwrap(currency)).approve(address(poolManager), amount);
        IERC20(Currency.unwrap(currency)).transferFrom(
            recipient,
            address(poolManager),
            amount
        );
        currency.settle(poolManager, recipient, uint256(amount), false);
    }

    function _arePoolKeysEqual(
        PoolKey storage a,
        PoolKey calldata b
    ) internal view returns (bool) {
        return
            a.currency0 == b.currency0 &&
            a.currency1 == b.currency1 &&
            a.fee == b.fee &&
            a.tickSpacing == b.tickSpacing;
    }

    function _isLargeSwap(
        uint128 liquidity,
        uint256 sqrtPriceX96,
        int256 swapAmount
    ) internal pure returns (bool) {
        uint256 reserve0 = (uint256(liquidity) * (1 << 96)) / sqrtPriceX96;
        uint256 thresholdAmount = (reserve0 * THRESHOLD) / 10000;

        return uint256(swapAmount) > thresholdAmount;
    }

    function _abs(
        IPoolManager.SwapParams calldata params
    ) internal pure returns (int256 swapAmount) {
        swapAmount = params.amountSpecified < 0
            ? -params.amountSpecified
            : params.amountSpecified;
    }

    function _closestUsableTick(
        uint160 sqrtPriceNextX96,
        int24 tickSpacing,
        bool findAbove
    ) internal pure returns (int24) {
        require(tickSpacing > 0, "Tick spacing must be positive");

        int24 tick = sqrtPriceNextX96.getTickAtSqrtPrice();

        if (findAbove) {
            int24 nextTick = ((tick + tickSpacing - 1) / tickSpacing) *
                tickSpacing;
            if (nextTick > TickMath.MAX_TICK) revert("No usable tick above");
            return nextTick;
        } else {
            int24 previousTick = (tick / tickSpacing) * tickSpacing;
            if (previousTick < TickMath.MIN_TICK)
                revert("No usable tick below");
            return previousTick;
        }
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }
}
