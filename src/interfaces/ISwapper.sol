// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.23;

interface ISwapper {
    function swap(address inToken, address outToken, uint256 amountOut) external;
}
