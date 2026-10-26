// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    PackedUserOperation
} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {BasePrivacyPaymaster} from "../BasePrivacyPaymaster.sol";
import {IPrivacyPool} from "./interfaces/IPrivacyPool.sol";

/// Paymaster for 0xbow `privacy-pools-core` withdrawals from any allowlisted
/// native ETH pool.
///
/// The paymaster acts as the withdrawal's `processooor`: the pool only lets
/// the processooor call `withdraw` and pushes the withdrawn value to it. The
/// paymaster keeps a fixed fee and forwards the remainder to the recipient.
/// The proof's `context` signal binds the whole `withdrawal` struct,
/// including the `FeeData` in `withdrawal.data`.
contract PrivacyPoolsPaymaster is BasePrivacyPaymaster {
    struct PaymasterData {
        IPrivacyPool pool;
        IPrivacyPool.Withdrawal withdrawal;
        IPrivacyPool.WithdrawProof proof;
    }

    /// Encoded in `withdrawal.data`, bound by the proof's `context` signal.
    struct FeeData {
        address recipient;
        uint256 fee;
    }

    /// Sentinel used by privacy-pools-core to represent the native asset.
    address internal constant NATIVE_ASSET =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ----- ERRORS -----
    error PoolNotAllowed(address pool);
    error NotEthPool(address pool);
    error FeeExceedsWithdrawal(uint256 fee, uint256 received);
    error PayoutFailed();

    // ----- STATE -----
    mapping(IPrivacyPool => bool) public pools;

    // ----- EVENTS -----
    event PoolSet(address indexed pool, bool allowed);

    constructor(IEntryPoint _entryPoint) BasePrivacyPaymaster(_entryPoint) {}

    // ----- ADMIN -----
    function setPool(
        IPrivacyPool pool,
        bool allowed
        // aderyn-ignore-next-line(centralization-risk)
    ) external onlyOwner {
        if (allowed && pool.ASSET() != NATIVE_ASSET) {
            revert NotEthPool(address(pool));
        }
        pools[pool] = allowed;
        emit PoolSet(address(pool), allowed);
    }

    // ----- BasePrivacyPaymaster -----
    function _collectFee(
        PackedUserOperation calldata userOp
    ) internal override returns (uint256, address) {
        PaymasterData memory d = abi.decode(
            _paymasterData(userOp),
            (PaymasterData)
        );
        // Only allowlisted pools are trusted to actually push the funds.
        if (!pools[d.pool]) revert PoolNotAllowed(address(d.pool));

        FeeData memory feeData = abi.decode(d.withdrawal.data, (FeeData));
        _checkCallGasLimit(userOp, feeData.recipient);

        uint256 balanceBefore = address(this).balance;
        d.pool.withdraw(d.withdrawal, d.proof);
        uint256 received = address(this).balance - balanceBefore;
        if (feeData.fee > received) {
            revert FeeExceedsWithdrawal(feeData.fee, received);
        }

        (bool ok, ) = feeData.recipient.call{value: received - feeData.fee}("");
        if (!ok) revert PayoutFailed();
        return (feeData.fee, feeData.recipient);
    }
}
