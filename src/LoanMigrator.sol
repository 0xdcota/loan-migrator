// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.23;

import {ILendingPool} from "./interfaces/aave-v2/ILendingPool.sol";
import {IFlashLoanReceiver} from "./interfaces/aave-v2/IFlashLoanReceiver.sol";
import {IERC20, IERC20WithPermit} from "./interfaces/IERC20WithPermit.sol";
import {IDebtToken} from "./interfaces/aave-v2/IDebtToken.sol";

struct Account {
    address token;
    uint256 amount;
}

struct AccountWithPermit {
    address token;
    uint256 amount;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

contract LoanMigrator is IFlashLoanReceiver {
    bytes32 internal _securityHash;

    /// @notice Migrate from Aave-v2 to Aave-v2 loan position, consolidating all debt in `final`
    /// debt token at `to` ILendingPool.
    /// @dev
    /// - pre-requisite: caller must credit delegate this address at least amount in
    /// - pre-requisite: caller must give erc20 approval for at least the amount in `aTokens`
    /// - pre-requisite: user most have applicable debt in variable rate mode (2)
    ///   https://docs.aave.com/developers/v/2.0/the-core-protocol/lendingpool#borrow
    /// @param from lending pool
    /// @param to lending pool
    /// @param aTokens with Accounts (aToken addr, amount)
    /// @param debts with Accounts (erc20, amount)
    /// @param finalDebt debtToken
    function migrateLoan(
        ILendingPool from,
        ILendingPool to,
        Account[] calldata aTokens,
        Account[] calldata debts,
        IDebtToken finalDebt
    ) public {
        address holder = msg.sender;
        _checkATokenApprovals(holder, aTokens);
        uint256 finalAmount = _checkBorrowAllowance(debts, finalDebt);
        (address[] memory assets, uint256[] memory amounts, uint256[] memory modes) = _getFlashloanInputs(debts);
        bytes memory migration = _createMigration(holder, from, to, aTokens, debts, finalDebt);
        _recordSecurityHash(address(to), assets, amounts, address(this), migration);
        to.flashLoan(address(this), assets, amounts, modes, address(this), migration, 0);
    }

    /// @dev Required flashloan callback
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address, /*initiator*/
        bytes calldata params
    ) external override returns (bool) {
        _checkSecurityHash(msg.sender, assets, amounts, params);
    }

    function _checkATokenApprovals(address holder, Account[] calldata aTokens) internal pure {
        // TODO revert if no ERC20Approval for at least amount.
    }

    function _checkBorrowAllowance(Account[] calldata debts, IERC20 finalDebt)
        internal
        view
        returns (uint256 finalAmount)
    {
        // TODO compute finalDebt amount from Debts.
    }

    function _getFlashloanInputs(Account[] calldata debtTokens)
        internal
        view
        returns (address[] memory, uint256[] memory, uint256[] memory)
    {
        uint256 len = debtTokens.length;
        address[] memory assets = new address[](len);
        uint256[] memory amounts = new uint256[](len);
        uint256[] memory modes = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            assets[i] = debtTokens[i].token;
            amounts[i] = debtTokens[i].amount;
        }
        return (assets, amounts, modes);
    }

    function _createMigration(
        address holder,
        ILendingPool from,
        ILendingPool to,
        Account[] calldata aTokens,
        Account[] calldata debt,
        IDebtToken finalDebt
    ) internal view returns (bytes memory) {
        uint256 callsLength = _getCallsLength(debt.length, aTokens.length);

        bytes[] memory calls = new bytes[](callsLength);
        uint256 currentIndex = _loadRepayCalls(holder, debt, calls);
        currentIndex = _loadAtokenTransferCalls(holder, debt, calls, currentIndex);
        _loadRepayCalls(holder, debt, calls);
    }

    function _recordSecurityHash(
        address flashloanProvider,
        address[] memory assets,
        uint256[] memory amounts,
        address recipient,
        bytes memory params
    ) internal {
        require(_securityHash.length == 0, "_securityHash in wrong state");
        bytes32 hashedCallback = keccak256(abi.encodePacked(flashloanProvider, assets, amounts, recipient, params));
        _securityHash = hashedCallback;
    }

    function _checkSecurityHash(
        address flashloanCaller,
        address[] memory assets,
        uint256[] memory amounts,
        bytes memory params
    ) internal {
        bytes32 hashedCallback = keccak256(abi.encodePacked(flashloanCaller, assets, amounts, address(this), params));
        require(_securityHash == hashedCallback, "bad security hash");
        delete _securityHash;
    }

    function _getCallsLength(uint256 debtLength, uint256 aTokenLength) internal view returns (uint256) {
        return debtLength + aTokenLength;
    }

    function _loadRepayCalls(address holder, Account[] calldata debt, bytes[] memory calls)
        internal
        view
        returns (uint256 lastIndex)
    {
        uint256 len = debt.length;
        for (uint256 i = 0; i < len; i++) {
            calls[i] = abi.encodeWithSelector(ILendingPool.repay.selector, debt[i].token, debt[i].amount, 2, holder);
        }
        lastIndex = len;
    }

    function _loadAtokenTransferCalls(
        address holder,
        Account[] calldata aTokens,
        bytes[] memory calls,
        uint256 startIndex
    ) internal view returns (uint256 lastIndex) {
        uint256 len = aTokens.length;
        for (uint256 i = 0; i < len; i++) {
            calls[startIndex] = abi.encodeWithSelector(
                IERC20WithPermit.safeTransferFrom.selector, aTokens[i].token, aTokens[i].amount, 2, holder
            );
            startIndex++;
        }
        lastIndex = startIndex + 1;
    }
}
