// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2, console, stdError} from "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import "@uniswap/v4-core/test/utils/Constants.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/types/BalanceDelta.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/libraries/Hooks.sol";

import {JITRebalancerHook} from "../src/JITRebalancerHook.sol";
import {AuctionManager} from "../src/base/AuctionManager.sol";
import "../src/constants/Constants.sol";

contract JITRebalancerHookTest is Test, Deployers {
    event NewBalanceDelta(int256 amount0, int256 amount1);
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    JITRebalancerHook jitRebalancerHook;
    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20();
        token0.mint(address(this), type(uint256).max);

        token1 = new MockERC20();
        token1.mint(address(this), type(uint256).max);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        address hookAddress = address(flags);

        deployCodeTo("JITRebalancerHook.sol", abi.encode(manager), hookAddress);
        jitRebalancerHook = JITRebalancerHook((hookAddress));

        token0.approve(address(modifyLiquidityRouter), 250 ether);
        token1.approve(address(modifyLiquidityRouter), 250 ether);

        (key, ) = initPoolAndAddLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            jitRebalancerHook,
            3000,
            SQRT_PRICE_1_1
        );

        token0.approve(address(swapRouter), 100 ether);
        // token1.approve(address(swapRouter), 100 ether);

        token0.approve(address(jitRebalancerHook), 250 ether);
        token1.approve(address(jitRebalancerHook), 250 ether);
    }

    function testRegisterBid() public {
        uint128 poolLiquidityBefore = manager.getLiquidity(key.toId());
        console.log("Pool liquidity Before: %d", poolLiquidityBefore);

        uint256 minLiquidity = (uint256(poolLiquidityBefore) * THRESHOLD) /
            10000;

        console.log("Min liquidity: %d", minLiquidity);

        int256 liquidityDelta = int256(minLiquidity + 20 ether);

        console.log("Liquidity delta: %d", liquidityDelta);

        AuctionManager.BidPosition memory bidPosition = AuctionManager
            .BidPosition({
                bidderAddress: address(this),
                key: key,
                params: IPoolManager.ModifyLiquidityParams({
                    tickLower: -60,
                    tickUpper: 60,
                    liquidityDelta: liquidityDelta,
                    salt: bytes32(0)
                })
            });

        jitRebalancerHook.registerBid(bidPosition);

        AuctionManager.BidPosition[] memory bids;

        bids = jitRebalancerHook.getBids(key.toId());

        console.log("Bids length: %d", bids.length);
        console.log("Bids[0].liquidity: %d", bids[0].params.liquidityDelta);
        assertEq(bids.length, 1);
        assertEq(bids[0].params.liquidityDelta, liquidityDelta);
    }

    function testBeforeSwap() public {
        uint128 poolLiquidityBefore = manager.getLiquidity(key.toId());
        console.log("Pool liquidity Before: %d", poolLiquidityBefore);

        uint256 minLiquidity = (uint256(poolLiquidityBefore) * THRESHOLD) /
            10000;

        console.log("Min liquidity: %d", minLiquidity);

        int256 liquidityDelta = int256(minLiquidity + 10 ether);

        console.log("Liquidity delta: %d", liquidityDelta);

        AuctionManager.BidPosition memory bidPosition = AuctionManager
            .BidPosition({
                bidderAddress: address(this),
                key: key,
                params: IPoolManager.ModifyLiquidityParams({
                    tickLower: -60,
                    tickUpper: 60,
                    liquidityDelta: liquidityDelta,
                    salt: bytes32(0)
                })
            });

        jitRebalancerHook.registerBid(bidPosition);

        uint256 token0BalanceBefore = token0.balanceOf(address(this));
        uint256 token1BalanceBefore = token1.balanceOf(address(this));

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // Large swap
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(
            key,
            swapParams,
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        uint256 token0BalanceAfter = token0.balanceOf(address(this));
        uint256 token1BalanceAfter = token1.balanceOf(address(this));

        // assertLt(token0BalanceAfter, token0BalanceBefore);
        // assertGt(token1BalanceAfter, token1BalanceBefore);

        JITRebalancerHook.BidPosition[] memory bids = jitRebalancerHook.getBids(
            key.toId()
        );
        assertEq(bids.length, 1);
    }

    function testSwap() public {
        // @dev: pre-commit liquidity for a swap
        uint128 poolLiquidityBefore = manager.getLiquidity(key.toId());

        uint256 minLiquidity = (uint256(poolLiquidityBefore) * THRESHOLD) /
            10000;

        int256 liquidityDelta = int256(minLiquidity + 200 ether);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager
            .ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            });

        // @dev: prepare a swap

        uint128 poolLiquidity = manager.getLiquidity(key.toId());
        console.log("Pool liquidity Before Swap: %d", poolLiquidity);

        uint256 token0BalanceBefore = token0.balanceOf(address(this));
        uint256 token1BalanceBefore = token1.balanceOf(address(this));

        console.log(
            "Token0 balance Before Swap: %d",
            token0.balanceOf(address(this))
        );
        console.log(
            "Token1 balance Before Swap: %d",
            token1.balanceOf(address(this))
        );

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 20 ether, // Large swap
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(
            key,
            swapParams,
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hex""
        );

        uint256 token0BalanceAfter = token0.balanceOf(address(this));
        uint256 token1BalanceAfter = token1.balanceOf(address(this));

        console.log(
            "Token0 balance After Swap: %d",
            token0.balanceOf(address(this))
        );
        console.log(
            "Token1 balance After Swap: %d",
            token1.balanceOf(address(this))
        );
        assertLt(token0BalanceAfter, token0BalanceBefore);
        assertGt(token1BalanceAfter, token1BalanceBefore);

        JITRebalancerHook.BidPosition[] memory bids = jitRebalancerHook.getBids(
            key.toId()
        );
        assertEq(bids.length, 0);
    }
}
