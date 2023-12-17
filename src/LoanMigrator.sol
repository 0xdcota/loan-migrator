// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.23;

import {ILendingPool} from "./interfaces/aave-v2/ILendingPool.sol";
import {IFlashLoanReceiver} from "./interfaces/aave-v2/IFlashLoanReceiver.sol";
import {IERC20, IERC20WithPermit} from "./interfaces/IERC20WithPermit.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IDebtToken} from "./interfaces/aave-v2/IDebtToken.sol";

struct Account {
    address token;
    uint256 amount;
}

// TODO the Atokens can be transferred with a signed permit.
struct AccountWithPermit {
    address token;
    uint256 amount;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

contract LoanMigrator is IFlashLoanReceiver {
    using Address for address;

    bytes32 internal _securityHash;
    // TODO need to set up swapper and consider the allowances to swap.
    ISwapper public swapper;

    /// @notice Migrate from Aave-v2 to Aave-v2 loan position, consolidating all debt into a `finalDebt`
    /// in the `to` ILendingPool.
    /// @dev
    /// - pre-requisite: caller must credit delegate this address at least amount in
    /// - pre-requisite: caller must give erc20 approval for at least the amount in `aTokens`
    /// - pre-requisite: user most have applicable debt in variable rate mode (2)
    ///   https://docs.aave.com/developers/v/2.0/the-core-protocol/lendingpool#borrow
    /// @param from lending pool
    /// @param to lending pool
    /// @param aTokens with Accounts (aToken addr, amount)
    /// @param debts with Accounts (erc20, amount)
    /// @param finalDebt state of migration
    function migrateLoan(
        ILendingPool from,
        ILendingPool to,
        Account[] calldata aTokens,
        Account[] calldata debts,
        Account calldata finalDebt
    ) public {
        address holder = msg.sender;
        _checkATokenApprovals(holder, aTokens);
        _checkBorrowAllowance(holder, IDebtToken(finalDebt.token));
        (address[] memory assets, uint256[] memory amounts, uint256[] memory modes) = _getFlashloanInputs(debts);
        bytes memory migration = _createMigration(holder, from, to, aTokens, debts, finalDebt);
        _recordSecurityHash(address(to), assets, amounts, address(this), migration);
        to.flashLoan(address(this), assets, amounts, modes, address(this), migration, 0);
    }

    /// @dev Required flashloan callback
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata, /*premiums*/
        address, /*initiator*/
        bytes calldata migration
    ) external override returns (bool) {
        _checkSecurityHash(msg.sender, assets, amounts, migration);
        (address[] memory callees, bytes[] memory calls) = abi.decode(migration, (address[], bytes[]));
        uint256 len = callees.length;
        for (uint256 i = 0; i < len; i++) {
            _executeCall(callees[i], calls[i]);
        }
        //TODO add erc20-approvals for flashloan payback or find a way to do it during configurations
        return true;
    }

    function _checkATokenApprovals(address holder, Account[] calldata aTokens) internal pure {
        // TODO revert if no ERC20Approval for at least amount.
    }

    function _checkBorrowAllowance(address holder, IDebtToken finalDebt) internal pure {
        // TODO check borrow allowance is enough
    }

    function _getFlashloanInputs(Account[] calldata debtTokens)
        internal
        pure
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
        Account[] calldata debts,
        Account calldata finalDebt
    ) internal view returns (bytes memory) {
        uint256 callsLength = _getCallsLength(debts.length, aTokens.length);
        address[] memory callees = new address[](callsLength);
        bytes[] memory calls = new bytes[](callsLength);
        uint256 currentIndex = _loadRepayCalls(holder, from, debts, callees, calls);
        currentIndex = _loadAtokenTransferCalls(holder, aTokens, callees, calls, currentIndex);
        currentIndex = _loadDepositCalls(holder, to, aTokens, callees, calls, currentIndex);
        currentIndex = _loadTakeLoan(holder, to, finalDebt, callees, calls, currentIndex);
        currentIndex = _loadRequiredSwaps(to, finalDebt, debts, callees, calls, currentIndex);
        return abi.encode(callees, calls);
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

    function _getCallsLength(uint256 debtLength, uint256 aTokenLength) internal pure returns (uint256) {
        // 1 for each repay fo all debts
        // 2 * each aTokens to move (erc20.tranferFrom + deposit)
        // 1 to take final loan to pay back the flashloan
        //
        return debtLength + 2 * aTokenLength + 1;
    }

    function _estimatePremium(uint256 flashAmount) internal pure returns (uint256 fee) {
        // TODO make external code or hardcode how to compute flashamount fee
    }

    function _loadRepayCalls(
        address holder,
        ILendingPool from,
        Account[] calldata debt,
        address[] memory callees,
        bytes[] memory calls
    ) internal pure returns (uint256 lastIndex) {
        uint256 len = debt.length;
        for (uint256 i = 0; i < len; i++) {
            callees[i] = address(from);
            calls[i] = abi.encodeWithSelector(ILendingPool.repay.selector, debt[i].token, debt[i].amount, 2, holder);
        }
        lastIndex = len;
    }

    function _loadAtokenTransferCalls(
        address holder,
        Account[] calldata aTokens,
        address[] memory callees,
        bytes[] memory calls,
        uint256 startIndex
    ) internal view returns (uint256 lastIndex) {
        uint256 len = aTokens.length;
        for (uint256 i = 0; i < len; i++) {
            callees[startIndex] = aTokens[i].token;
            calls[startIndex] =
                abi.encodeWithSelector(IERC20.transferFrom.selector, holder, address(this), aTokens[i].amount);
            startIndex++;
        }
        lastIndex = startIndex + 1;
    }

    function _loadDepositCalls(
        address holder,
        ILendingPool to,
        Account[] calldata aTokens,
        address[] memory callees,
        bytes[] memory calls,
        uint256 startIndex
    ) internal pure returns (uint256 lastIndex) {
        uint256 len = aTokens.length;
        for (uint256 i = 0; i < len; i++) {
            callees[startIndex] = address(to);
            calls[startIndex] =
                abi.encodeWithSelector(ILendingPool.deposit.selector, aTokens[i].token, aTokens[i].amount, holder, 0);
            startIndex++;
        }
        lastIndex = startIndex + 1;
    }

    function _loadTakeLoan(
        address holder,
        ILendingPool to,
        Account calldata finalDebt,
        address[] memory callees,
        bytes[] memory calls,
        uint256 startIndex
    ) internal pure returns (uint256 lastIndex) {
        callees[startIndex] = address(to);
        calls[startIndex] =
            abi.encodeWithSelector(ILendingPool.borrow.selector, finalDebt.token, finalDebt.amount, 2, 0, holder);
        lastIndex = startIndex + 1;
    }

    function _loadRequiredSwaps(
        ILendingPool to,
        Account calldata finalDebt,
        Account[] calldata debts,
        address[] memory callees,
        bytes[] memory calls,
        uint256 startIndex
    ) internal pure returns (uint256 lastIndex) {
        // Need to consider how to protect slippage here
        uint256 len = debts.length;
        for (uint256 i = 0; i < len; i++) {
            if (finalDebt.token != debts[i].token) {
                callees[startIndex] = address(to);
                calls[startIndex] = abi.encodeWithSelector(
                    ISwapper.swap.selector,
                    finalDebt.token,
                    debts[i].token,
                    debts[i].amount + _estimatePremium(debts[i].amount)
                );
                startIndex++;
            }
        }
        lastIndex = startIndex + 1;
    }

    function _executeCall(address target, bytes memory data) private returns (bytes memory) {
        return target.functionCallWithValue(data, 0);
    }
}
