// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v4-core/src/types/BalanceDelta.sol";

library Return {
    function delta(
        BalanceDelta _delta
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        int128 amount0delta = _delta.amount0();
        int128 amount1delta = _delta.amount1();

        if (amount0delta != 0) {
            amount0 = _delta.amount0() < 0
                ? uint256(int256(-_delta.amount0()))
                : uint256(int256(_delta.amount0()));
        } else {
            amount0 = 0;
        }

        if (amount1delta != 0) {
            amount1 = _delta.amount1() < 0
                ? uint256(int256(-_delta.amount1()))
                : uint256(int256(_delta.amount1()));
        } else {
            amount1 = 0;
        }
    }
}
