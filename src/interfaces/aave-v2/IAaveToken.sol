// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.23;

import {IERC20WithPermit} from "../IERC20WithPermit.sol";

interface IAaveToken is IERC20WithPermit {
    /**
     * @dev Returns the address of the underlying asset of this aaveToken (E.g. WETH for aWETH)
     *
     */
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
