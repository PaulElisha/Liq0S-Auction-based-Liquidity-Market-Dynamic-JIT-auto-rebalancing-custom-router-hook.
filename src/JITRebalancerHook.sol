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
import "./libraries/TrySwap.sol";
import "./libraries/TickExtended.sol";
import "./libraries/PoolExtended.sol";
import "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {Test, console2, console, stdError} from "forge-std/Test.sol";

contract JITRebalancerHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SwapMath for uint160;
    using TickMath for uint160;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolExtended for *;
    using TickExtended for *;
    using TrySwap for IPoolManager;
    using SafeCast for *;

    mapping(PoolId poolId => PoolExtended.Info info) public poolInfo;
    mapping(PoolId poolId => PoolKey key) public pools;
    mapping(PoolId poolId => Bid[]) public bids;

    uint256 public constant THRESHOLD = 100; // 1% threshold in Basis Points Scale

    struct Bid {
        address bidderAddress;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        int256 liquidityDelta;
    }

    Bid winningBid;

    struct CallbackData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        address sender;
    }

    struct DeltaAmounts {
        uint256 amount0Delta;
        uint256 amount1Delta;
    }

    mapping(address sender => DeltaAmounts) amounts;

    event BidRegistered(
        address indexed bidder,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        int256 liquidityDelta
    );

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        CallbackData memory _data = abi.decode(data, (CallbackData));

        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            _data.key,
            _data.params,
            hex""
        );

        uint256 amount0Delta = delta.amount0() < 0
            ? uint256(uint128(-delta.amount0()))
            : uint256(uint128(delta.amount0()));

        uint256 amount1Delta = delta.amount1() < 0
            ? uint256(uint128(-delta.amount1()))
            : uint256(uint128(delta.amount1()));

        amounts[_data.sender] = DeltaAmounts({
            amount0Delta: amount0Delta,
            amount1Delta: amount1Delta
        });

        console.log(
            "amount0Delta: %d, amount1Delta: %d",
            amount0Delta,
            amount1Delta
        );

        _transferAndSettle(_data.key.currency0, _data.sender, amount0Delta);
        _transferAndSettle(_data.key.currency1, _data.sender, amount1Delta);

        return hex"";
    }

    function _transferAndSettle(
        Currency currency,
        address sender,
        uint256 amount
    ) internal {
        IERC20(Currency.unwrap(currency)).transferFrom(
            sender,
            address(this),
            amount
        );
        currency.settle(poolManager, address(this), amount, false);
    }

    function addLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params
    ) external {
        uint128 poolLiquidity = poolManager.getLiquidity(key.toId());

        uint256 minLiquidity = (uint256(poolLiquidity) * THRESHOLD) / 10000;

        require(
            uint256(params.liquidityDelta) >= minLiquidity,
            "Insufficient liquidity for large swaps"
        );

        poolManager.unlock(
            abi.encode(
                CallbackData({key: key, params: params, sender: msg.sender})
            )
        );

        _registerLPBid(msg.sender, key, 0, 0, params);
    }

    function _registerLPBid(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        IPoolManager.ModifyLiquidityParams calldata params
    ) internal {
        PoolId poolId = key.toId();

        if (!_arePoolKeysEqual(pools[poolId], key)) {
            pools[poolId] = key;
        }

        require(params.tickLower < params.tickUpper, "Invalid ticks");

        bids[poolId].push(
            Bid({
                bidderAddress: sender,
                poolId: poolId,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0: amount0,
                amount1: amount1,
                liquidityDelta: params.liquidityDelta
            })
        );

        emit BidRegistered(
            sender,
            poolId,
            params.tickLower,
            params.tickUpper,
            amount0,
            amount1,
            params.liquidityDelta
        );
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        require(_arePoolKeysEqual(pools[poolId], key), "pool key not found");

        {
            poolInfo.update(poolId, poolManager);
        }

        uint160 sqrtPriceX96;
        uint128 liquidity;

        {
            (sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
            liquidity = poolManager.getLiquidity(poolId);
        }

        int256 swapAmount = _abs(swapParams);

        bool islargeSwap;

        {
            islargeSwap = _isLargeSwap(liquidity, sqrtPriceX96, swapAmount);
        }

        BeforeSwapDelta deltas;
        if (islargeSwap) {
            deltas = _executeLargeSwap(poolId, key, swapParams);
        }

        return (this.beforeSwap.selector, deltas, 0);
    }

    function _executeLargeSwap(
        PoolId poolId,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams
    ) internal returns (BeforeSwapDelta) {
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

        return toBeforeSwapDelta(result.amount0(), result.amount1());
    }

    function swapStepHook(
        PoolId poolId,
        Pool.StepComputations memory step,
        Pool.SwapResult memory state
    ) internal {
        PoolKey memory key = pools[poolId];

        if (state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized) {
            {
                poolInfo[poolId].ticks.cross(
                    step.tickNext,
                    poolInfo[poolId].secondsPerLiquidityGlobalX128
                );
            }

            int24 tickLower;
            int24 tickUpper;

            {
                (tickLower, tickUpper) = _getUsableTicks(
                    step.sqrtPriceNextX96,
                    key.tickSpacing
                );
            }

            {
                winningBid = _selectWinningBid(poolId);
                require(
                    winningBid.bidderAddress != address(0),
                    "No valid bids"
                );
            }

            {
                _adjustLiquidity(key, tickLower, tickUpper, state, winningBid);
            }
        }
    }

    function _adjustLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        Pool.SwapResult memory state,
        Bid memory _winningBid
    ) internal {
        _removeLiquidity(key, _winningBid);
        // Bid memory _winningBid = winningBid;
        _winningBid.amount0 = amounts[_winningBid.bidderAddress].amount0Delta;
        _winningBid.amount1 = amounts[_winningBid.bidderAddress].amount1Delta;
        uint128 liquidityDelta;
        {
            liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                state.sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                _winningBid.amount0,
                _winningBid.amount1
            );
        }

        _winningBid.tickLower = tickLower;
        _winningBid.tickUpper = tickUpper;
        _winningBid.liquidityDelta = int256(int128(liquidityDelta));

        _addLiquidity(key, _winningBid);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
        Bid memory _winningBid = winningBid;

        _removeLiquidity(key, _winningBid);

        // @dev: delete the pool from the mapping
        delete bids[key.toId()];

        return (this.afterSwap.selector, 0);
    }

    function _addLiquidity(
        PoolKey memory key,
        Bid memory _winningBid
    ) internal {
        {
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: _winningBid.tickLower,
                    tickUpper: _winningBid.tickUpper,
                    liquidityDelta: _winningBid.liquidityDelta,
                    salt: 0
                }),
                hex""
            );

            _handleBalanceAccounting(delta, address(this), key);
        }

        winningBid = _winningBid;
    }

    function _removeLiquidity(
        PoolKey memory key,
        Bid memory _winningBid
    ) internal {
        {
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: _winningBid.tickLower,
                    tickUpper: _winningBid.tickUpper,
                    liquidityDelta: -int256(_winningBid.liquidityDelta),
                    salt: 0
                }),
                hex""
            );

            _handleBalanceAccounting(delta, address(this), key);
        }
    }

    function getBids(PoolId poolId) external view returns (Bid[] memory) {
        return bids[poolId];
    }

    function _getUsableTicks(
        uint160 sqrtPriceNextX96,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        tickLower = _closestUsableTick(sqrtPriceNextX96, tickSpacing, false);
        tickUpper = _closestUsableTick(sqrtPriceNextX96, tickSpacing, true);
    }

    function _selectWinningBid(
        PoolId poolId
    ) internal returns (Bid memory _winningBid) {
        Bid[] storage poolBids = bids[poolId];
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        uint256 minLiquidityForLargeSwap = (uint256(poolLiquidity) *
            THRESHOLD) / 10000;

        // @dev: cache the following parameters
        uint256 winningBidIndex = 0;
        int256 maxBidLiquidity = 0;

        for (uint256 i = 0; i < poolBids.length; i++) {
            if (poolBids[i].liquidityDelta >= maxBidLiquidity) {
                winningBidIndex = i;
                maxBidLiquidity = poolBids[i].liquidityDelta;
            }
        }

        if (maxBidLiquidity >= int256(minLiquidityForLargeSwap)) {
            _winningBid = poolBids[winningBidIndex];
            poolBids[winningBidIndex] = poolBids[poolBids.length - 1];
            poolBids.pop();
        }
    }

    function _handleBalanceAccounting(
        BalanceDelta delta,
        address recipient,
        PoolKey memory key
    ) internal {
        delta.amount0() < 0
            ? key.currency0.settle(
                poolManager,
                recipient,
                uint256(uint128(-delta.amount0())),
                false
            )
            : poolManager.take(
                key.currency0,
                recipient,
                uint128(delta.amount0())
            );

        delta.amount1() < 0
            ? key.currency1.settle(
                poolManager,
                recipient,
                uint256(uint128(-delta.amount1())),
                false
            )
            : poolManager.take(
                key.currency1,
                recipient,
                uint128(delta.amount1())
            );
    }

    function _arePoolKeysEqual(
        PoolKey storage a,
        PoolKey calldata b
    ) internal view returns (bool) {
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
