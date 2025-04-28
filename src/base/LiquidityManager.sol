// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import "./Payments.sol";
import "../constants/Constants.sol";
import "../structs/CallbackStruct.sol";

library LiquidityManager {
    using StateLibrary for IPoolManager;

    // function addLiquidityCallback() public {}

    function addLiquidity(
        IPoolManager poolManager,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory _data
    ) public {
        uint128 poolLiquidity = poolManager.getLiquidity(key.toId());

        uint256 minLiquidity = (uint256(poolLiquidity) * THRESHOLD) / 10000;

        require(
            uint256(params.liquidityDelta) > minLiquidity,
            "Insufficient liquidity for large swaps"
        );

        AddLiquidityCallback memory data = abi.decode(
            _data,
            (AddLiquidityCallback)
        );

        if (data.amount0 > 0)
            Payments.pay(poolManager, key.currency0, data.payer, data.amount0);

        if (data.amount1 > 0)
            Payments.pay(poolManager, key.currency1, data.payer, data.amount1);
    }

    function removeLiquidity(
        IPoolManager poolManager,
        PoolKey memory key,
        uint256 amount0Owned,
        uint256 amount1Owned
    ) internal {
        if (amount0Owned > 0) {
            uint256 balance = IERC20(Currency.unwrap(key.currency0)).balanceOf(
                address(poolManager)
            );

            if (balance >= amount0Owned) {
                Payments.take(poolManager, key.currency0, amount0Owned);
            }
        }

        if (amount1Owned > 0) {
            uint256 balance = IERC20(Currency.unwrap(key.currency0)).balanceOf(
                address(poolManager)
            );

            if (balance >= amount1Owned) {
                Payments.take(poolManager, key.currency0, amount1Owned);
            }
        }
    }
}
