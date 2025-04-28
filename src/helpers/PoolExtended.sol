// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickExtended} from "./TickExtended.sol";

library PoolExtended {
    using StateLibrary for *;

    struct Info {
        uint48 lastBlockTimestamp;
        uint176 secondsPerLiquidityGlobalX128;
        mapping(int24 tick => TickExtended.Info) ticks;
    }

    /// @notice Updates the global state of the pool
    /// @param id The pool id
    /// @param poolManager The pool manager
    /// @return pool The pool extended state
    function update(
        mapping(PoolId => PoolExtended.Info) storage self,
        PoolId id,
        IPoolManager poolManager
    ) internal returns (PoolExtended.Info storage pool) {
        pool = self[id];
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity != 0) {
            uint160 secondsPerLiquidityX128 = uint160(
                FullMath.mulDiv(
                    block.timestamp - pool.lastBlockTimestamp,
                    FixedPoint128.Q128,
                    liquidity
                )
            );
            pool.secondsPerLiquidityGlobalX128 += secondsPerLiquidityX128;
        }
        pool.lastBlockTimestamp = uint48(block.timestamp);
    }

    function getPoolState(
        IPoolManager poolManager,
        PoolId poolId
    )
        internal
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint24 protocolFee,
            uint24 lpFee,
            uint128 liquidityStart
        )
    {
        (sqrtPriceX96, tick, protocolFee, lpFee) = poolManager.getSlot0(poolId);

        liquidityStart = poolManager.getLiquidity(poolId);
    }
}
