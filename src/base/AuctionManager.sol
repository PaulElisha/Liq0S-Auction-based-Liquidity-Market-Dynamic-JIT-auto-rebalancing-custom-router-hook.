// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";

import "../constants/Constants.sol";
import {Test, console2, console, stdError} from "forge-std/Test.sol";

abstract contract AuctionManager {
    using StateLibrary for IPoolManager;

    mapping(PoolId poolId => BidPosition[]) public bids;
    mapping(PoolId poolId => PoolKey key) public pools;

    event BidRegistered(
        address bidder,
        IPoolManager.ModifyLiquidityParams params
    );

    event BidUpdated(
        address indexed bidder,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1
    );

    struct BidPosition {
        // Bid Position
        address bidderAddress;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    BidPosition public highestBidder;

    function registerBid(BidPosition memory bidPosition) public {
        PoolId poolId = bidPosition.key.toId();

        if (!arePoolKeysEqual(pools[poolId], bidPosition.key)) {
            pools[poolId] = bidPosition.key;
        }

        require(
            bidPosition.params.tickLower < bidPosition.params.tickUpper,
            "Invalid ticks"
        );

        console.log("Bidder Address:", msg.sender);

        bids[poolId].push(
            BidPosition({
                bidderAddress: msg.sender,
                key: bidPosition.key,
                params: bidPosition.params
            })
        );

        emit BidRegistered(msg.sender, bidPosition.params);
    }

    function getBids(PoolId poolId) public view returns (BidPosition[] memory) {
        return bids[poolId];
    }

    function selectWinningBid(
        IPoolManager poolManager,
        PoolId poolId
    ) internal returns (BidPosition memory _winningBid) {
        BidPosition[] storage poolBids = bids[poolId];
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        uint256 minLiquidity = (uint256(poolLiquidity) * THRESHOLD) / 10000;

        uint256 winningIndex = type(uint256).max;
        int256 maxLiquidity;

        for (uint256 i; i < poolBids.length; ) {
            BidPosition memory bid = poolBids[i];
            if (
                bid.params.liquidityDelta > maxLiquidity &&
                bid.params.liquidityDelta > int256(minLiquidity)
            ) {
                maxLiquidity = bid.params.liquidityDelta;
                winningIndex = i;
            }
            unchecked {
                ++i;
            }
        }

        if (winningIndex != type(uint256).max) {
            _winningBid = poolBids[winningIndex];
            poolBids[winningIndex] = poolBids[poolBids.length - 1];
            poolBids.pop();

            require(
                _winningBid.params.tickLower < _winningBid.params.tickUpper,
                "Invalid bid ticks"
            );
        } else {
            revert("No qualifying bids");
        }
    }

    function arePoolKeysEqual(
        PoolKey storage a,
        PoolKey memory b
    ) internal view returns (bool) {
        return
            a.currency0 == b.currency0 &&
            a.currency1 == b.currency1 &&
            a.fee == b.fee &&
            a.tickSpacing == b.tickSpacing;
    }
}
