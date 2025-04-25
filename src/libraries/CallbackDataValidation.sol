// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library CallbackDataValidation {
    function verifyCallbackData(address poolManager) public view {
        require(msg.sender == poolManager, "Not PM");
    }
}
