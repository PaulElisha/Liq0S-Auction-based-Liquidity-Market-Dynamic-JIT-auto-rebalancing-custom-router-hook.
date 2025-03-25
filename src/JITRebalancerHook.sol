// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

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
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./libraries/trySwap.sol";
import "./libraries/PoolExtended.sol";

contract JITRebalancerHook is BaseHook, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SwapMath for uint160;
    using TickMath for uint160;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolExtended for *;
    using TrySwap for IPoolManager;

    mapping(PoolId ppolId => PoolExtended.Info info) public pools;
    mapping(PoolId poolId => PoolKey key) public poolKeys;
    // mapping(PoolKey key => PoolId poolId) public poolIds;
    mapping(PoolId poolId => int256 amountSpecifiedRemaining)
        public idToAmountSpecifiedRemaining;
    mapping(PoolId => Bid[]) public bids;

    uint256 public constant THRESHOLD = 100; // 1% threshold in Basis Points Scale

    struct Bid {
        address bidderAddress;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    function _arePoolKeysEqual(
        PoolKey storage a,
        PoolKey calldata b
    ) internal pure returns (bool) {
        return
            a.currency0 == b.currency0 &&
            a.currency1 == b.currency1 &&
            a.fee == b.fee &&
            a.tickSpacing == b.tickSpacing;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) external override nonReentrant returns (bytes4, BeforeSwapDelta, uint24) {
        Currency tokenA = key.currency0;
        Currency tokenB = key.currency1;

        require(
            _arePoolKeysEqual(poolKeys[key.toId()], key),
            "pool key not the same"
        );

        PoolId poolId = key.toId();

        pools.update(poolId, poolManager);
        // poolKeys[poolId] = key;
        idToAmountSpecifiedRemaining[poolId] = swapParams.amountSpecified;

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        (int256 swapAmount, bool exactInput) = abs(swapParams);

        uint160 sqrtPriceTargetX96 = swapParams.zeroForOne || exactInput
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;
        bool islargeSwap = isLargeSwap(liquidity, sqrtPriceX96, swapAmount);

        if (islargeSwap) {
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

            // @dev: delete the pool from the mapping
            delete idToAmountSpecifiedRemaining[poolId];
            delete poolKeys[poolId];

            BeforeSwapDelta deltas = toBeforeSwapDelta(
                result.amount0(),
                result.amount1()
            );
            return (this.beforeSwap.selector, deltas, 0);
        }
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        address sender = abi.decode(hookData, (address));
        _registerLPBid(
            sender,
            key,
            key.toId(),
            params.tickLower,
            params.tickUpper,
            int128(int256(params.liquidityDelta))
        );

        return (this.afterAddLiquidity.selector, delta);
    }

    function _registerLPBid(
        address sender,
        PoolKey memory key,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) internal {
        poolKeys[poolId] = key;

        require(
            key.tickSpacing <= tickLower && tickLower < tickUpper,
            "Invalid ticks"
        );

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        uint256 minLiquidity = (uint256(poolLiquidity) * THRESHOLD) / 10000;

        require(
            uint256(uint128(liquidityDelta)) >= minLiquidity,
            "Insufficient liquidity for large swaps"
        );

        bids[poolId].push(
            Bid({
                bidderAddress: sender,
                poolId: poolId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(int128(liquidityDelta))
            })
        );
    }

    function _selectWinningBid(
        PoolId poolId
    ) internal view returns (Bid memory winningBid) {
        Bid[] storage poolBids = bids[poolId];
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        uint256 winningBidIndex = 0;
        uint256 maxBidLiquidity = 0;
        uint256 winningBidLiquidity = 0;

        uint256 minLiquidityForLargeSwap = (uint256(poolLiquidity) *
            THRESHOLD) / 10000;

        for (uint256 i = 0; i < poolBids.length; i++) {
            if (poolBids[i].liquidityDelta >= 0 && maxBidLiquidity > 0) {
                winningBidIndex = i;
                maxBidLiquidity = uint256(poolBids[i].liquidityDelta);
                winningBidLiquidity = maxBidLiquidity;
            }
        }

        if (maxBidLiquidity >= minLiquidityForLargeSwap) {
            winningBid = poolBids[winningBidIndex];
            poolBids[winningBidIndex] = poolBids[poolBids.length - 1];
            poolBids.pop();

            return winningBid;
        }
    }

    // function _getLiquidity(
    //     PoolKey memory key,
    //     int24 tickLower,
    //     int24 tickUpper
    // ) internal view returns (uint128) {
    //     PositionConfig memory config = PositionConfig({
    //         poolKey: key,
    //         tickLower: tickLower,
    //         tickUpper: tickUpper
    //     });

    //     bytes32 positionId = PositionConfigLibrary.toId(config);

    //     (uint128 liquidity, , , ) = poolManager.getPosition(positionId);
    //     return liquidity;
    // }

    function swapStepHook(
        PoolId poolId,
        Pool.StepComputations memory step,
        Pool.SwapResult memory state
    ) internal {
        PoolKey memory key = poolKeys[poolId];
        int256 amountSpecifiedRemaining = idToAmountSpecifiedRemaining[poolId];

        if (state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized) {
            int24 tickLower = closestUsableTick(
                step.sqrtPriceNextX96,
                key.tickSpacing,
                false
            );
            int24 tickUpper = closestUsableTick(
                step.sqrtPriceNextX96,
                key.tickSpacing,
                true
            );

            uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                uint256(amountSpecifiedRemaining)
            );

            Bid memory winningBid = _selectWinningBid(poolId);
            require(winningBid.bidderAddress != address(0), "No valid bids");
            // uint128 _liquidityDelta = _getLiquidity(
            //     poolKeys[winningBid.poolId],
            //     winningBid.tickLower,
            //     winningBid.tickUpper,
            //     winningBid.liquidityDelta
            // );

            if (winningBid.liquidityDelta > 0) {
                (BalanceDelta _delta, ) = poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: winningBid.tickLower,
                        tickUpper: winningBid.tickUpper,
                        liquidityDelta: -int256(
                            uint256(winningBid.liquidityDelta)
                        ), // adjust remove liquidity
                        salt: 0
                    }),
                    hex""
                );

                handleBalanceAccounting(_delta, address(this), key);
            }

            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidityDelta)),
                    salt: 0
                }),
                hex""
            );

            winningBid.tickLower = tickLower;
            winningBid.tickUpper = tickUpper;
            winningBid.liquidityDelta = int256(uint256(liquidityDelta));

            handleBalanceAccounting(delta, address(this), key);
        }
    }

    function handleBalanceAccounting(
        BalanceDelta delta,
        address recipient,
        PoolKey memory key
    ) internal {
        if (delta.amount0() > 0) {
            poolManager.take(
                key.currency0,
                recipient,
                uint128(delta.amount0())
            ); // take from the old LP pool
        } else if (delta.amount0() < 0) {
            IERC20(Currency.unwrap(key.currency0)).approve(
                address(poolManager),
                uint128(-delta.amount0())
            );
            IERC20(Currency.unwrap(key.currency0)).transferFrom( // approve and transfer to the computed pool parameter
                recipient,
                address(poolManager),
                uint128(-delta.amount0())
            );

            key.currency0.settle( // settle balances with the pool manager
                poolManager,
                recipient,
                uint256(uint128(-delta.amount0())),
                false
            );
        }

        if (delta.amount1() > 0) {
            poolManager.take(
                key.currency1,
                recipient,
                uint128(delta.amount1())
            );
        } else if (delta.amount1() < 0) {
            IERC20(Currency.unwrap(key.currency1)).approve(
                address(poolManager),
                uint128(-delta.amount0())
            );
            IERC20(Currency.unwrap(key.currency1)).transferFrom(
                recipient,
                address(poolManager),
                uint128(-delta.amount1())
            );
            key.currency1.settle(
                poolManager,
                recipient,
                uint256(uint128(-delta.amount0())),
                false
            );
        }
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external override onlyPoolManager returns (bytes4, int128) {
        Bid memory winningBid = _selectWinningBid(key.toId());

        (BalanceDelta _delta, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: winningBid.tickLower,
                tickUpper: winningBid.tickUpper,
                liquidityDelta: -int256(uint256(winningBid.liquidityDelta)),
                salt: 0
            }),
            data
        );

        handleBalanceAccounting(_delta, winningBid.bidderAddress, key);

        return (this.afterSwap.selector, 0);
    }

    function isLargeSwap(
        uint128 liquidity,
        uint256 sqrtPriceX96,
        int256 swapAmount
    ) internal pure returns (bool) {
        uint256 reserve0 = (uint256(liquidity) * (1 << 96)) / sqrtPriceX96;
        uint256 thresholdAmount = (reserve0 * THRESHOLD) / 10000;

        return uint256(swapAmount) > thresholdAmount;
    }

    function abs(
        IPoolManager.SwapParams calldata params
    ) internal pure returns (int256, bool) {
        int256 swapAmount = params.amountSpecified < 0
            ? -params.amountSpecified
            : params.amountSpecified;

        bool exactInput = swapAmount == -params.amountSpecified ? true : false;
        return (swapAmount, exactInput);
    }

    function closestUsableTick(
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
