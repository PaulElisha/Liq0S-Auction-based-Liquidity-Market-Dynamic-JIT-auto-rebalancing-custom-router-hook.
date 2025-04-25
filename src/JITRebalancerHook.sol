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
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v4-core/src/libraries/SafeCast.sol";

import "./libraries/TrySwap.sol";
import "./libraries/TickExtended.sol";
import "./libraries/PoolExtended.sol";
import "./libraries/CallbackDataValidation.sol";
import "./base/Payments.sol";

import {Test, console2, console, stdError} from "forge-std/Test.sol";

contract JITRebalancerHook is BaseHook, Payments {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SwapMath for uint160;
    using TickMath for uint160;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolExtended for *;
    using TickExtended for *;
    using TrySwap for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 public constant THRESHOLD = 100; // 1% threshold in Basis Points Scale

    struct Bid {
        address bidderAddress;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint256 deltaAmount0;
        uint256 deltaAmount1;
        int256 liquidityDelta;
    }
    Bid highestBidder;

    struct CallbackData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        address payer;
    }

    struct DeltaAmounts {
        uint256 amount0Delta;
        uint256 amount1Delta;
    }

    mapping(address sender => DeltaAmounts) amounts;
    mapping(PoolId poolId => PoolExtended.Info info) public poolInfo;
    mapping(PoolId poolId => PoolKey key) public pools;
    mapping(PoolId poolId => Bid[]) public bids;

    event BidRegistered(
        address bidder,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 deltaAmount0,
        uint256 deltaAmount1,
        int256 liquidityDelta
    );

    event OptimalLiquidityProvision(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        uint256 amount0Owed,
        uint256 amount1Owed
    );

    event LiquidityRemoved(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        uint256 amount0Owned,
        uint256 amount1Owned
    );

    event BidderSelected(address bidder);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        CallbackDataValidation.verifyCallbackData(address(poolManager));

        CallbackData memory _data = abi.decode(data, (CallbackData));

        require(msg.sender == address(poolManager), "Not poolManager");

        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            _data.key,
            _data.params,
            hex""
        );

        (
            amounts[_data.payer].amount0Delta,
            amounts[_data.payer].amount1Delta
        ) = _returnDelta(delta);

        console.log(
            "Bidder %s, amount0Delta: %d, amount1Delta: %d",
            _data.payer,
            amounts[_data.payer].amount0Delta,
            amounts[_data.payer].amount1Delta
        );

        pay(
            poolManager,
            _data.key.currency0,
            _data.payer,
            amounts[_data.payer].amount0Delta
        );

        pay(
            poolManager,
            _data.key.currency1,
            _data.payer,
            amounts[_data.payer].amount1Delta
        );

        return hex"";
    }

    function addLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params
    ) external {
        uint128 poolLiquidity = poolManager.getLiquidity(key.toId());

        uint256 minLiquidity = (uint256(poolLiquidity) * THRESHOLD) / 10000;

        require(
            uint256(params.liquidityDelta) > minLiquidity,
            "Insufficient liquidity for large swaps"
        );

        poolManager.unlock(
            abi.encode(
                CallbackData({key: key, params: params, payer: msg.sender})
            )
        );

        _registerLPBid(msg.sender, key, amounts[msg.sender], params);
    }

    function _registerLPBid(
        address sender,
        PoolKey calldata key,
        DeltaAmounts memory amountsDelta,
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
                deltaAmount0: amountsDelta.amount0Delta,
                deltaAmount1: amountsDelta.amount1Delta,
                liquidityDelta: params.liquidityDelta
            })
        );

        emit BidRegistered(
            sender,
            poolId,
            params.tickLower,
            params.tickUpper,
            amountsDelta.amount0Delta,
            amountsDelta.amount1Delta,
            params.liquidityDelta
        );
    }

    struct SwapCache {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int256 swapAmount;
        bool islargeSwap;
        int24 tickLower;
        int24 tickUpper;
    }
    SwapCache cache;

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        require(
            _arePoolKeysEqual(pools[key.toId()], key),
            "pool key not found"
        );

        PoolId poolId = key.toId();

        {
            poolInfo.update(poolId, poolManager);
        }

        {
            (cache.sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
            cache.liquidity = poolManager.getLiquidity(poolId);
        }
        {
            cache.swapAmount = _abs(swapParams);
        }

        {
            cache.islargeSwap = _isLargeSwap(
                cache.liquidity,
                cache.sqrtPriceX96,
                cache.swapAmount
            );
        }

        BeforeSwapDelta deltas;
        if (cache.islargeSwap) {
            deltas = _executeLargeSwap(poolId, key.tickSpacing, swapParams);
        }

        return (this.beforeSwap.selector, deltas, 0);
    }

    function _executeLargeSwap(
        PoolId poolId,
        int24 tickSpacing,
        IPoolManager.SwapParams calldata swapParams
    ) internal returns (BeforeSwapDelta) {
        BalanceDelta result = poolManager.swap(
            poolId,
            Pool.SwapParams({
                tickSpacing: tickSpacing,
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
        {
            if (
                state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized
            ) {
                {
                    poolInfo[poolId].ticks.cross(
                        step.tickNext,
                        poolInfo[poolId].secondsPerLiquidityGlobalX128
                    );
                }

                {
                    (cache.tickLower, cache.tickUpper) = _getUsableTicks(
                        step.sqrtPriceNextX96,
                        key.tickSpacing
                    );
                }

                require(
                    cache.tickLower <= state.tick &&
                        state.tick <= cache.tickUpper,
                    "Position does not cover post-swap price"
                );

                {
                    _adjustLiquidity(key, cache, state);
                }
            }
        }
    }

    function _adjustLiquidity(
        PoolKey memory key,
        SwapCache memory _cache,
        Pool.SwapResult memory state
    ) internal {
        highestBidder = _selectWinningBid(key.toId());

        require(
            highestBidder.bidderAddress != address(0),
            "No valid bid for address"
        );

        emit BidderSelected(highestBidder.bidderAddress);

        // @dev: update the highestBidder amounts removed

        BalanceDelta highestBidderDelta = _removeLiquidity(key, highestBidder);

        (highestBidder.deltaAmount0, highestBidder.deltaAmount1) = _returnDelta(
            highestBidderDelta
        );

        console.log(
            "Removed amount0Delta: %d and amount1Delta: %d",
            highestBidder.deltaAmount0,
            highestBidder.deltaAmount1
        );
        // @dev: optimal liquidity addition for large swaps

        // @dev: optimal liquidityDelta for next range;
        {
            highestBidder.liquidityDelta = int256(
                int128(
                    LiquidityAmounts.getLiquidityForAmounts(
                        state.sqrtPriceX96,
                        TickMath.getSqrtPriceAtTick(_cache.tickLower),
                        TickMath.getSqrtPriceAtTick(_cache.tickUpper),
                        highestBidder.deltaAmount0,
                        highestBidder.deltaAmount1
                    )
                )
            );
        }

        // @dev: update next tick ranges
        highestBidder.tickLower = _cache.tickLower;
        highestBidder.tickUpper = _cache.tickUpper;

        _addLiquidity(key, highestBidder);
    }

    function _addLiquidity(
        PoolKey memory key,
        Bid memory _highestBidder
    ) internal {
        {
            (BalanceDelta deltaAdded, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: _highestBidder.tickLower,
                    tickUpper: _highestBidder.tickUpper,
                    liquidityDelta: _highestBidder.liquidityDelta,
                    salt: 0
                }),
                hex""
            );

            emit OptimalLiquidityProvision(
                _highestBidder.bidderAddress,
                _highestBidder.tickLower,
                _highestBidder.tickUpper,
                _highestBidder.liquidityDelta,
                uint256(uint128(_highestBidder.deltaAmount0)),
                uint256(uint128(_highestBidder.deltaAmount1))
            );

            _handleBalanceAccounting(deltaAdded, address(this), key);
        }
    }

    function _removeLiquidity(
        PoolKey memory key,
        Bid memory _highestBidder
    ) internal returns (BalanceDelta deltaRemoved) {
        {
            (deltaRemoved, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: _highestBidder.tickLower,
                    tickUpper: _highestBidder.tickUpper,
                    liquidityDelta: -_highestBidder.liquidityDelta,
                    salt: 0
                }),
                hex""
            );

            _handleBalanceAccounting(deltaRemoved, address(this), key);
        }
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
        Bid memory _highestBidder = highestBidder;
        {
            _transferTokensToBidder(
                key,
                address(this),
                int128(int256(delta.amount0())),
                int128(int256(delta.amount1()))
            );
        }

        emit LiquidityRemoved(
            _highestBidder.bidderAddress,
            _highestBidder.tickLower,
            _highestBidder.tickUpper,
            _highestBidder.liquidityDelta,
            uint256(uint128(delta.amount0())),
            uint256(uint128(delta.amount1()))
        );

        return (this.afterSwap.selector, 0);
    }

    function _transferTokensToBidder(
        PoolKey memory key,
        address bidder,
        int128 amount0,
        int128 amount1
    ) internal {
        {
            if (amount0 > 0) {
                uint256 amount0Owned = uint256(uint128(amount0));
                uint256 balance = IERC20(Currency.unwrap(key.currency0))
                    .balanceOf(address(poolManager));

                if (balance >= amount0Owned) {
                    poolManager.take(key.currency0, bidder, amount0Owned);
                }
            }

            if (amount1 > 0) {
                uint256 amount1Owned = uint256(uint128(amount1));
                uint256 balance = IERC20(Currency.unwrap(key.currency0))
                    .balanceOf(address(poolManager));

                if (balance >= amount1Owned) {
                    poolManager.take(key.currency0, bidder, amount1Owned);
                }
            }
        }
    }

    function getBids(PoolId poolId) public view returns (Bid[] memory) {
        return bids[poolId];
    }

    function _getUsableTicks(
        uint160 sqrtPriceNextX96,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 tick = sqrtPriceNextX96.getTickAtSqrtPrice();
        tickLower = _closestUsableTick(tick, tickSpacing, false);
        tickUpper = _closestUsableTick(tick, tickSpacing, true);
    }

    function _selectWinningBid(
        PoolId poolId
    ) internal returns (Bid memory _winningBid) {
        Bid[] storage poolBids = bids[poolId];
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        uint256 minLiquidity = (uint256(poolLiquidity) * THRESHOLD) / 10000;

        uint256 winningIndex = type(uint256).max;
        int256 maxLiquidity;

        for (uint256 i; i < poolBids.length; ) {
            Bid memory bid = poolBids[i];
            if (
                bid.liquidityDelta > maxLiquidity &&
                bid.liquidityDelta > int256(minLiquidity)
            ) {
                maxLiquidity = bid.liquidityDelta;
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
                _winningBid.tickLower < _winningBid.tickUpper,
                "Invalid bid ticks"
            );
        } else {
            revert("No qualifying bids");
        }
    }

    function _handleBalanceAccounting(
        BalanceDelta delta,
        address recipient,
        PoolKey memory key
    ) internal {
        if (delta.amount0() < 0) {
            uint256 amount0Owed = uint256(uint128(-delta.amount0()));
            key.currency0.settle(poolManager, recipient, amount0Owed, false);
        } else if (delta.amount0() > 0) {
            uint256 amount0Owned = uint256(uint128(delta.amount0()));
            uint256 balance = IERC20(Currency.unwrap(key.currency0)).balanceOf(
                address(poolManager)
            );

            if (balance >= amount0Owned) {
                poolManager.take(key.currency0, recipient, amount0Owned);
            }

            if (balance < amount0Owned) {
                poolManager.take(key.currency0, recipient, balance);
            }
        }

        if (delta.amount1() < 0) {
            uint256 amount1Owed = uint256(uint128(-delta.amount1()));
            key.currency1.settle(poolManager, recipient, amount1Owed, false);
        } else if (delta.amount1() > 0) {
            uint256 amount1Owned = uint256(uint128(delta.amount1()));
            uint256 balance = IERC20(Currency.unwrap(key.currency1)).balanceOf(
                address(poolManager)
            );

            if (balance >= amount1Owned) {
                poolManager.take(key.currency1, recipient, amount1Owned);
            }

            if (balance < amount1Owned) {
                poolManager.take(key.currency0, recipient, balance);
            }
        }
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
        int24 tick,
        int24 tickSpacing,
        bool findAbove
    ) internal pure returns (int24) {
        require(tickSpacing > 0, "Tick spacing must be positive");

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

    function _returnDelta(
        BalanceDelta _delta
    ) internal returns (uint256 amount0, uint256 amount1) {
        amount0 = _delta.amount0() < 0
            ? uint256(uint128(-_delta.amount0()))
            : uint256(uint128(_delta.amount0()));
        amount1 = _delta.amount1() < 0
            ? uint256(uint128(-_delta.amount1()))
            : uint256(uint128(_delta.amount1()));
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
