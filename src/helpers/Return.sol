// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v4-core/src/types/BalanceDelta.sol";

library Return {
    function delta(
        BalanceDelta _delta
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        amount0 = _delta.amount0() < 0
            ? uint256(int256(-_delta.amount0()))
            : uint256(int256(_delta.amount0()));
        amount1 = _delta.amount1() < 0
            ? uint256(int256(-_delta.amount1()))
            : uint256(int256(_delta.amount1()));
    }
}
