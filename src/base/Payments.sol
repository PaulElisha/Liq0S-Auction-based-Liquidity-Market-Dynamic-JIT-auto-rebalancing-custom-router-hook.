// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import "@uniswap/v4-core/src/types/Currency.sol";

abstract contract Payments {
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    function pay(
        IPoolManager poolManager,
        Currency currency,
        address sender,
        uint256 amount
    ) internal {
        IERC20(Currency.unwrap(currency)).safeTransferFrom(
            sender,
            address(this),
            amount
        );
        currency.settle(poolManager, address(this), amount, false);
    }
}
