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
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v4-core/src/libraries/SafeCast.sol";

import "./helpers/TrySwap.sol";
import "./helpers/TickExtended.sol";
import "./helpers/PoolExtended.sol";
import "./base/AuctionManager.sol";
import "./helpers/Return.sol";
import "./base/Jit.sol";

import {Test, console2, console, stdError} from "forge-std/Test.sol";

contract JITRebalancerHook is BaseHook, Jit {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SwapMath for uint160;
    using TickMath for uint160;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolExtended for *;
    using TickExtended for *;
    using SafeERC20 for IERC20;

    event OptimalLiquidityProvision(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        uint256 amount0Owed,
        uint256 amount1Owed
    );

    // event LiquidityRemoved(
    //     address sender,
    //     int24 tickLower,
    //     int24 tickUpper,
    //     int256 liquidityDelta,
    //     uint256 amount0Owned,
    //     uint256 amount1Owned
    // );

    event BidderSelected(address bidder);

    mapping(PoolId poolId => PoolExtended.Info info) public poolInfo;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    struct SwapCache {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int256 swapAmount;
        bool islargeSwap;
        int24 tickLower;
        int24 tickUpper;
    }
    SwapCache cache;

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // require(arePoolKeysEqual(pools[key.toId()], key), "pool key not found");

        PoolId poolId = key.toId();

        {
            poolInfo.update(poolId, poolManager);
        }

        {
            (cache.sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
            cache.liquidity = poolManager.getLiquidity(poolId);
        }
        {
            cache.swapAmount = _abs(swapParams);
        }

        {
            cache.islargeSwap = _isLargeSwap(
                cache.liquidity,
                cache.sqrtPriceX96,
                cache.swapAmount
            );
        }

        BeforeSwapDelta deltas;
        if (cache.islargeSwap) {
            deltas = _executeLargeSwap(poolId, key.tickSpacing, swapParams);
        }

        return (this.beforeSwap.selector, deltas, 0);
    }

    function _executeLargeSwap(
        PoolId poolId,
        int24 tickSpacing,
        IPoolManager.SwapParams calldata swapParams
    ) internal returns (BeforeSwapDelta) {
        BalanceDelta result = TrySwap.swap(
            poolManager,
            poolId,
            Pool.SwapParams({
                tickSpacing: tickSpacing,
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
        {
            if (
                state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized
            ) {
                {
                    poolInfo[poolId].ticks.cross(
                        step.tickNext,
                        poolInfo[poolId].secondsPerLiquidityGlobalX128
                    );
                }

                {
                    (cache.tickLower, cache.tickUpper) = _getUsableTicks(
                        step.sqrtPriceNextX96,
                        key.tickSpacing
                    );
                }

                // require(
                //     cache.tickLower <= state.tick &&
                //         state.tick <= cache.tickUpper,
                //     "Position does not cover post-swap price"
                // );

                {
                    injectLiquidity(poolManager, key, cache);
                }
            }
        }
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
        BidPosition memory _highestBidder = highestBidder;

        (uint256 amount0Delta, uint256 amount1Delta) = Return.delta(delta);

        sendLiquidityToBidder(poolManager, key, amount0Delta, amount1Delta);

        // emit LiquidityRemoved(
        //     _highestBidder.bidderAddress,
        //     _highestBidder.params.tickLower,
        //     _highestBidder.params.tickUpper,
        //     _highestBidder.params.liquidityDelta,
        //     uint256(uint128(delta.amount0())),
        //     uint256(uint128(delta.amount1()))
        // );

        return (this.afterSwap.selector, 0);
    }

    function _getUsableTicks(
        uint160 sqrtPriceNextX96,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 tick = sqrtPriceNextX96.getTickAtSqrtPrice();
        tickLower = _closestUsableTick(tick, tickSpacing, false);
        tickUpper = _closestUsableTick(tick, tickSpacing, true);
    }

    // function _handleBalanceAccounting(
    //     BalanceDelta delta,
    //     address recipient,
    //     PoolKey memory key
    // ) internal {
    //     if (delta.amount0() < 0) {
    //         uint256 amount0Owed = uint256(uint128(-delta.amount0()));
    //         key.currency0.settle(poolManager, recipient, amount0Owed, false);
    //     } else if (delta.amount0() > 0) {
    //         uint256 amount0Owned = uint256(uint128(delta.amount0()));
    //         uint256 balance = IERC20(Currency.unwrap(key.currency0)).balanceOf(
    //             address(poolManager)
    //         );

    //         if (balance >= amount0Owned) {
    //             poolManager.take(key.currency0, recipient, amount0Owned);
    //         }

    //         if (balance < amount0Owned) {
    //             poolManager.take(key.currency0, recipient, balance);
    //         }
    //     }

    //     if (delta.amount1() < 0) {
    //         uint256 amount1Owed = uint256(uint128(-delta.amount1()));
    //         key.currency1.settle(poolManager, recipient, amount1Owed, false);
    //     } else if (delta.amount1() > 0) {
    //         uint256 amount1Owned = uint256(uint128(delta.amount1()));
    //         uint256 balance = IERC20(Currency.unwrap(key.currency1)).balanceOf(
    //             address(poolManager)
    //         );

    //         if (balance >= amount1Owned) {
    //             poolManager.take(key.currency1, recipient, amount1Owned);
    //         }

    //         if (balance < amount1Owned) {
    //             poolManager.take(key.currency0, recipient, balance);
    //         }
    //     }
    // }

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
        int24 tick,
        int24 tickSpacing,
        bool findAbove
    ) internal pure returns (int24) {
        require(tickSpacing > 0, "Tick spacing must be positive");

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
                afterAddLiquidity: false,
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
