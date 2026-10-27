// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {BasePrivacyPaymaster} from "../BasePrivacyPaymaster.sol";
import {IPrivacyPool} from "./interfaces/IPrivacyPool.sol";

/// Paymaster for 0xbow `privacy-pools-core` withdrawals from any allowlisted
/// pool.
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

    struct Pool {
        bool allowed;
        /// The pool's asset, or address(0) for native pools.
        address asset;
    }

    /// Sentinel used by privacy-pools-core to represent the native asset.
    address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ----- ERRORS -----
    error PoolNotAllowed(address pool);
    error FeeExceedsWithdrawal(uint256 fee, uint256 received);
    error PayoutFailed();

    // ----- STATE -----
    mapping(IPrivacyPool => Pool) public pools;

    // ----- EVENTS -----
    event PoolSet(address indexed pool, bool allowed);

    constructor(IEntryPoint _entryPoint, IUniswapV3Factory _factory, address _weth, uint32 _twapPeriod)
        BasePrivacyPaymaster(_entryPoint, _factory, _weth, _twapPeriod)
    {}

    // ----- ADMIN -----

    /// Allows or disallows a Privacy Pools pool.
    function setPool(
        IPrivacyPool pool,
        bool allowed
        // aderyn-ignore-next-line(centralization-risk)
    )
        external
        onlyOwner
    {
        address asset = pool.ASSET();
        pools[pool] = Pool({allowed: allowed, asset: asset == NATIVE_ASSET ? address(0) : asset});
        emit PoolSet(address(pool), allowed);
    }

    // ----- BasePrivacyPaymaster -----

    /// Withdraws from the pool, keeps the fee, and forwards the rest.
    ///
    /// Measures the amount received by balance change, so fee-on-transfer
    /// tokens work.
    function _collectFee(PackedUserOperation calldata userOp)
        internal
        override
        returns (address feeToken, uint256 feePaid, address refundRecipient)
    {
        PaymasterData memory d = abi.decode(_paymasterData(userOp), (PaymasterData));
        // Only allowlisted pools are trusted to actually push the funds.
        Pool memory pool = pools[d.pool];
        if (!pool.allowed) revert PoolNotAllowed(address(d.pool));

        FeeData memory feeData = abi.decode(d.withdrawal.data, (FeeData));
        _requireSenderIsRecipientOrNoCalls(userOp, feeData.recipient);

        uint256 balanceBefore = _balance(pool.asset);
        d.pool.withdraw(d.withdrawal, d.proof);
        uint256 received = _balance(pool.asset) - balanceBefore;
        if (feeData.fee > received) {
            revert FeeExceedsWithdrawal(feeData.fee, received);
        }

        if (!_trySafeTransfer(pool.asset, feeData.recipient, received - feeData.fee)) {
            revert PayoutFailed();
        }
        return (pool.asset, feeData.fee, feeData.recipient);
    }

    /// Returns this contract's balance of `asset` (address(0) for ETH).
    function _balance(address asset) internal view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }
}
