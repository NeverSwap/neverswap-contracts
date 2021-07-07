// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

interface IERC20Burnable {
    function burnFrom(address _address, uint256 _amount) external;

    function mint(address _address, uint256 m_amount) external;
}
