// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import "@uniswap/v4-core/src/libraries/Pool.sol";
import "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import "@uniswap/v4-core/src/libraries/SafeCast.sol";
import "@uniswap/v4-core/src/libraries/SwapMath.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/types/BalanceDelta.sol";
import "@uniswap/v4-core/src/types/Slot0.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import {TickBitmapModified} from "./TickBitmapModified.sol";
import {PoolExtended} from "./PoolExtended.sol";

library TrySwap {
    using CustomRevert for bytes4;
    using LPFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint24;
    using SafeCast for *;
    using StateLibrary for IPoolManager;
    using PoolExtended for IPoolManager;

    function swap(
        IPoolManager poolManager,
        PoolId poolId,
        Pool.SwapParams memory params,
        function(
            PoolId,
            Pool.StepComputations memory,
            Pool.SwapResult memory
        ) swapStepHook
    ) internal returns (BalanceDelta result) {
        uint24 swapFee;
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        Pool.SwapResult memory state;
        bool zeroForOne = params.zeroForOne;
        bool exactInput = params.amountSpecified < 0;
        uint256 protocolFee;
        {
            (
                uint160 _sqrtPriceX96,
                int24 _tick,
                uint24 _protocolFee,
                uint24 _lpFee,
                uint128 _liquidityStart
            ) = poolManager.getPoolState(poolId);

            protocolFee = zeroForOne
                ? _protocolFee.getZeroForOneFee()
                : _protocolFee.getOneForZeroFee();

            amountSpecifiedRemaining = params.amountSpecified;
            amountCalculated = 0;

            state = Pool.SwapResult({
                sqrtPriceX96: _sqrtPriceX96,
                tick: _tick,
                liquidity: _liquidityStart
            });

            {
                uint24 lpFee = params.lpFeeOverride.isOverride()
                    ? params.lpFeeOverride.removeOverrideFlagAndValidate()
                    : _lpFee;

                swapFee = protocolFee == 0
                    ? lpFee
                    : ProtocolFeeLibrary.calculateSwapFee(
                        uint16(_protocolFee),
                        lpFee
                    );
            }

            if (!exactInput && (swapFee == LPFeeLibrary.MAX_LP_FEE)) {
                Pool.InvalidFeeForExactOut.selector.revertWith();
            }

            if (params.amountSpecified == 0)
                return BalanceDeltaLibrary.ZERO_DELTA;

            if (zeroForOne) {
                if (params.sqrtPriceLimitX96 >= _sqrtPriceX96) {
                    Pool.PriceLimitAlreadyExceeded.selector.revertWith(
                        _sqrtPriceX96,
                        params.sqrtPriceLimitX96
                    );
                }
                if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                    Pool.PriceLimitOutOfBounds.selector.revertWith(
                        params.sqrtPriceLimitX96
                    );
                }
            } else {
                if (params.sqrtPriceLimitX96 <= _sqrtPriceX96) {
                    Pool.PriceLimitAlreadyExceeded.selector.revertWith(
                        _sqrtPriceX96,
                        params.sqrtPriceLimitX96
                    );
                }
                if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                    Pool.PriceLimitOutOfBounds.selector.revertWith(
                        params.sqrtPriceLimitX96
                    );
                }
            }
        }
        Pool.StepComputations memory step;

        while (
            !(amountSpecifiedRemaining == 0 ||
                state.sqrtPriceX96 == params.sqrtPriceLimitX96)
        ) {
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = TickBitmapModified
                .nextInitializedTickWithinOneWord(
                    poolManager,
                    poolId,
                    state.tick,
                    params.tickSpacing,
                    zeroForOne
                );

            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut,
                step.feeAmount
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(
                    zeroForOne,
                    step.sqrtPriceNextX96,
                    params.sqrtPriceLimitX96
                ),
                state.liquidity,
                amountSpecifiedRemaining,
                swapFee
            );

            if (!exactInput) {
                unchecked {
                    amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                amountCalculated =
                    amountCalculated -
                    (step.amountIn + step.feeAmount).toInt256();
            } else {
                unchecked {
                    amountSpecifiedRemaining += (step.amountIn + step.feeAmount)
                        .toInt256();
                }
                amountCalculated = amountCalculated + step.amountOut.toInt256();
            }

            if (protocolFee > 0) {
                unchecked {
                    uint256 delta = ((step.amountIn + step.feeAmount) *
                        protocolFee) / ProtocolFeeLibrary.PIPS_DENOMINATOR;
                    step.feeAmount -= delta;
                }
            }

            swapStepHook(poolId, step, state);

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    (, int128 liquidityNet) = poolManager.getTickLiquidity(
                        poolId,
                        step.tickNext
                    );
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity,
                        liquidityNet
                    );
                }

                unchecked {
                    int24 _zeroForOne;
                    assembly {
                        _zeroForOne := zeroForOne
                    }
                    state.tick = step.tickNext - _zeroForOne;
                }
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }
        }

        unchecked {
            if (zeroForOne != exactInput) {
                result = toBalanceDelta(
                    amountCalculated.toInt128(),
                    (params.amountSpecified - amountSpecifiedRemaining)
                        .toInt128()
                );
            } else {
                result = toBalanceDelta(
                    (params.amountSpecified - amountSpecifiedRemaining)
                        .toInt128(),
                    amountCalculated.toInt128()
                );
            }
        }
    }
}
