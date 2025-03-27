// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2, console} from "forge-std/Test.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IQuoter} from "v4-periphery/src/interfaces/IQuoter.sol";
import {Quoter} from "v4-periphery/src/lens/Quoter.sol";
import {JITRebalancerHook} from "../src/JITRebalancerHook.sol";

contract JITRebalancerHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    JITRebalancerHook jitRebalancerHook;
    Currency token0;
    Currency token1;

    Quoter public quoter;
    address pairPool;

    event NewBalanceDelta(int128 delta0, int128 delta1);

    function setUp() public {
        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );

        address hookAddress = address(flags);

        deployCodeTo("JITRebalancerHook.sol", abi.encode(manager), hookAddress);
        jitRebalancerHook = JITRebalancerHook(hookAddress);

        (key, ) = initPool(
            token0,
            token1,
            jitRebalancerHook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );
    }
}
