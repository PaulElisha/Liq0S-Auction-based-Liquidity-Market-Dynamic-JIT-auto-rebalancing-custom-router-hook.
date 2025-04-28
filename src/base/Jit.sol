// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import "../JITRebalancerHook.sol";
import "./LiquidityManager.sol";
import "./AuctionManager.sol";
import "../structs/CallbackStruct.sol";
import "../helpers/Return.sol";

abstract contract Jit is AuctionManager {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    function injectLiquidity(
        IPoolManager poolManager,
        PoolKey memory key,
        JITRebalancerHook.SwapCache memory _cache
    ) internal {
        highestBidder = selectWinningBid(poolManager, key.toId());

        require(
            highestBidder.bidderAddress != address(0),
            "No valid bid for address"
        );

        highestBidder.params.tickLower = _cache.tickLower;
        highestBidder.params.tickUpper = _cache.tickUpper;

        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            key,
            highestBidder.params,
            hex""
        );

        (uint256 amount0Delta, uint256 amount1Delta) = Return.delta(delta);

        LiquidityManager.addLiquidity(
            poolManager,
            key,
            highestBidder.params,
            abi.encode(
                AddLiquidityCallback({
                    amount0: amount0Delta,
                    amount1: amount1Delta,
                    payer: highestBidder.bidderAddress
                })
            )
        );
    }

    function sendLiquidityToBidder(
        IPoolManager poolManager,
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1
    ) public {
        LiquidityManager.removeLiquidity(poolManager, key, amount0, amount1);

        console.log("Bidder Address:", highestBidder.bidderAddress);

        // IERC20(Currency.unwrap(key.currency0)).safeTransfer(
        //     highestBidder.bidderAddress,
        //     amount0
        // );

        // IERC20(Currency.unwrap(key.currency1)).safeTransfer(
        //     highestBidder.bidderAddress,
        //     amount1
        // );
    }
}
