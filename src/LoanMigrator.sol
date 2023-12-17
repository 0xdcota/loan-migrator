// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.23;

struct Account {
    address token;
    uint256 amount;
}

contract LoanMigrator {
    /// @dev Migrate an Aave-v2 type of loan position
    function migrateLoan(Account[] calldata aTokens, Account[] calldata debtTokens) public {}
}
