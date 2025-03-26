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
import "./libraries/TrySwap.sol";
import "./libraries/TickExtended.sol";
import "./libraries/PoolExtended.sol";

contract JITRebalancerHook is BaseHook, ReentrancyGuard {
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

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

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
            params.liquidityDelta
        );

        return (this.afterAddLiquidity.selector, delta);
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) external override nonReentrant returns (bytes4, BeforeSwapDelta, uint24) {
        Currency tokenA = key.currency0;
        Currency tokenB = key.currency1;

        require(
            _arePoolKeysEqual(pools[key.toId()], key),
            "pool key not found"
        );

        PoolId poolId = key.toId();

        poolInfo.update(poolId, poolManager);
        idToAmountSpecifiedRemaining[poolId] = swapParams.amountSpecified;

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        int256 swapAmount = _abs(swapParams);

        bool islargeSwap = _isLargeSwap(liquidity, sqrtPriceX96, swapAmount);

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

            BeforeSwapDelta deltas = toBeforeSwapDelta(
                result.amount0(),
                result.amount1()
            );
            return (this.beforeSwap.selector, deltas, 0);
        }
    }

    function swapStepHook(
        PoolId poolId,
        Pool.StepComputations memory step,
        Pool.SwapResult memory state
    ) internal {
        PoolKey memory key = pools[poolId];

        if (state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized) {
            poolInfo[poolId].ticks.cross(
                step.tickNext,
                poolInfo[poolId].secondsPerLiquidityGlobalX128
            );

            int24 tickLower = _closestUsableTick(
                step.sqrtPriceNextX96,
                key.tickSpacing,
                false
            );
            int24 tickUpper = _closestUsableTick(
                step.sqrtPriceNextX96,
                key.tickSpacing,
                true
            );

            int128 amount0;
            int128 amount1;

            Bid memory winningBid = _selectWinningBid(poolId);
            require(winningBid.bidderAddress != address(0), "No valid bids");

            (BalanceDelta _delta, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: winningBid.tickLower,
                    tickUpper: winningBid.tickUpper,
                    liquidityDelta: -int256(winningBid.liquidityDelta), // adjust remove liquidity
                    salt: 0
                }),
                hex""
            );

            amount0 = _delta.amount0();
            amount1 = _delta.amount1();

            _handleBalanceAccounting(_delta, address(this), key);

            uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                state.sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                uint256(uint128(amount0)),
                uint256(uint128(amount1))
            );

            winningBid.tickLower = tickLower;
            winningBid.tickUpper = tickUpper;
            winningBid.liquidityDelta = int128(liquidityDelta);

            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(int128(liquidityDelta)),
                    salt: 0
                }),
                hex""
            );

            _handleBalanceAccounting(delta, address(this), key);
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
                liquidityDelta: -int256(winningBid.liquidityDelta),
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
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal {
        if (!_arePoolKeysEqual(pools[poolId], key)) {
            pools[poolId] = key;
        }

        require(
            key.tickSpacing <= tickLower && tickLower < tickUpper,
            "Invalid ticks"
        );

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        uint256 minLiquidity = (uint256(poolLiquidity) * THRESHOLD) / 10000;

        require(
            uint256(liquidityDelta) >= minLiquidity,
            "Insufficient liquidity for large swaps"
        );

        bids[poolId].push(
            Bid({
                bidderAddress: sender,
                poolId: poolId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta
            })
        );
    }

    function _selectWinningBid(
        PoolId poolId
    ) internal view returns (Bid memory winningBid) {
        Bid[] storage poolBids = bids[poolId];
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        // @dev: cache the following parameters
        uint256 winningBidIndex = 0;
        int256 maxBidLiquidity = 0;
        int256 winningBidLiquidity = 0;

        uint256 minLiquidityForLargeSwap = (uint256(poolLiquidity) *
            THRESHOLD) / 10000;

        for (uint256 i = 0; i < poolBids.length; i++) {
            if (poolBids[i].liquidityDelta >= maxBidLiquidity) {
                winningBidIndex = i;
                maxBidLiquidity = poolBids[i].liquidityDelta;
                winningBidLiquidity = maxBidLiquidity;
            }
        }

        if (maxBidLiquidity >= int256(minLiquidityForLargeSwap)) {
            winningBid = poolBids[winningBidIndex];
            poolBids[winningBidIndex] = poolBids[poolBids.length - 1];
            poolBids.pop();

            return winningBid;
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
            IERC20(Currency.unwrap(key.currency0)).approve(
                address(poolManager),
                uint128(-delta.amount0())
            );
            IERC20(Currency.unwrap(key.currency0)).transferFrom(
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
                uint128(-delta.amount1())
            );
            IERC20(Currency.unwrap(key.currency1)).transferFrom(
                recipient,
                address(poolManager),
                uint128(-delta.amount1())
            );
            key.currency1.settle(
                poolManager,
                recipient,
                uint256(uint128(-delta.amount1())),
                false
            );
        }
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

        return (swapAmount);
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
