// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";

library Payments {
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    function pay(
        IPoolManager poolManager,
        Currency currency,
        address payer,
        uint256 amount
    ) internal {
        IERC20(Currency.unwrap(currency)).safeTransferFrom(
            payer,
            address(this),
            amount
        );
        currency.settle(poolManager, address(this), amount, false);
    }

    function take(
        IPoolManager poolManager,
        Currency currency,
        uint256 amount0Owned
    ) public {
        currency.take(poolManager, address(this), amount0Owned, false);
    }
}
