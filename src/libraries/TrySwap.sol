// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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

    struct SwapStepState {
        uint24 swapFee;
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        bool exactInput;
        uint256 protocolFee;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidityStart;
        uint24 lpFee;
    }

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
        SwapStepState memory swapStepState;

        // uint24 swapFee;
        // int256 amountSpecifiedRemaining;
        // int256 amountCalculated;
        Pool.SwapResult memory state;
        bool zeroForOne = params.zeroForOne;
        swapStepState.exactInput = params.amountSpecified < 0;
        // uint256 protocolFee;
        {
            uint24 protocolfee;
            uint24 lpfee;
            (
                swapStepState.sqrtPriceX96,
                swapStepState.tick,
                protocolfee,
                lpfee,
                swapStepState.liquidityStart
            ) = poolManager.getPoolState(poolId);

            swapStepState.protocolFee = zeroForOne
                ? protocolfee.getZeroForOneFee()
                : protocolfee.getOneForZeroFee();

            swapStepState.amountSpecifiedRemaining = params.amountSpecified;
            swapStepState.amountCalculated = 0;

            state = Pool.SwapResult({
                sqrtPriceX96: swapStepState.sqrtPriceX96,
                tick: swapStepState.tick,
                liquidity: swapStepState.liquidityStart
            });

            {
                swapStepState.lpFee = params.lpFeeOverride.isOverride()
                    ? params.lpFeeOverride.removeOverrideFlagAndValidate()
                    : lpfee;

                swapStepState.swapFee = swapStepState.protocolFee == 0
                    ? lpfee
                    : ProtocolFeeLibrary.calculateSwapFee(
                        uint16(protocolfee),
                        swapStepState.lpFee
                    );
            }

            if (
                !swapStepState.exactInput &&
                (swapStepState.swapFee == LPFeeLibrary.MAX_LP_FEE)
            ) {
                Pool.InvalidFeeForExactOut.selector.revertWith();
            }

            if (params.amountSpecified == 0)
                return BalanceDeltaLibrary.ZERO_DELTA;

            if (zeroForOne) {
                if (params.sqrtPriceLimitX96 >= swapStepState.sqrtPriceX96) {
                    Pool.PriceLimitAlreadyExceeded.selector.revertWith(
                        swapStepState.sqrtPriceX96,
                        params.sqrtPriceLimitX96
                    );
                }
                if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                    Pool.PriceLimitOutOfBounds.selector.revertWith(
                        params.sqrtPriceLimitX96
                    );
                }
            } else {
                if (params.sqrtPriceLimitX96 <= swapStepState.sqrtPriceX96) {
                    Pool.PriceLimitAlreadyExceeded.selector.revertWith(
                        swapStepState.sqrtPriceX96,
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
            !(swapStepState.amountSpecifiedRemaining == 0 ||
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
                swapStepState.amountSpecifiedRemaining,
                swapStepState.swapFee
            );

            if (!swapStepState.exactInput) {
                unchecked {
                    swapStepState.amountSpecifiedRemaining -= step
                        .amountOut
                        .toInt256();
                }
                swapStepState.amountCalculated =
                    swapStepState.amountCalculated -
                    (step.amountIn + step.feeAmount).toInt256();
            } else {
                unchecked {
                    swapStepState.amountSpecifiedRemaining += (step.amountIn +
                        step.feeAmount).toInt256();
                }
                swapStepState.amountCalculated =
                    swapStepState.amountCalculated +
                    step.amountOut.toInt256();
            }

            if (swapStepState.protocolFee > 0) {
                unchecked {
                    uint256 delta = ((step.amountIn + step.feeAmount) *
                        swapStepState.protocolFee) /
                        ProtocolFeeLibrary.PIPS_DENOMINATOR;
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
            if (zeroForOne != swapStepState.exactInput) {
                result = toBalanceDelta(
                    swapStepState.amountCalculated.toInt128(),
                    (params.amountSpecified -
                        swapStepState.amountSpecifiedRemaining).toInt128()
                );
            } else {
                result = toBalanceDelta(
                    (params.amountSpecified -
                        swapStepState.amountSpecifiedRemaining).toInt128(),
                    swapStepState.amountCalculated.toInt128()
                );
            }
        }
    }
}
