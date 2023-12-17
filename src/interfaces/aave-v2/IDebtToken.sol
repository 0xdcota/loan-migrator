// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.23;

import {IERC20} from "../IERC20.sol";
import {ICreditDelegationToken} from "./ICreditDelegationToken.sol";

interface IDebtToken is IERC20, ICreditDelegationToken {
    /**
     * @dev Returns the address of the underlying asset of this aaveToken (E.g. WETH for aWETH)
     *
     */
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
