// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

interface IOracle {
    function consult(address _token, uint256 _amountIn)
        external
        view
        returns (uint256 _amountOut);
}
