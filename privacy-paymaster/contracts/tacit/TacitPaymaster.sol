// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {BasePrivacyPaymaster} from "../BasePrivacyPaymaster.sol";
import {ITacitPool} from "./interfaces/ITacitPool.sol";

/// Paymaster for withdrawals from allowlisted Tacit EVM pools (native ETH).
///
/// The paymaster acts as the withdrawal's relayer, so the pool pays the fee
/// directly to it. The proof binds `relayer`, so proofs for this paymaster
/// must be generated with `relayer = address(this)`.
///
/// Only withdrawals that insert no leaves are accepted. A proof that inserts
/// is built against the pool's current head and goes stale when any other
/// transaction reaches the pool first, so one cheap transaction could
/// invalidate every pending operation at once. A withdrawal that inserts
/// nothing proves membership against a root the pool has held and cannot go
/// stale; the only way to invalidate it is to spend its note. The whole note
/// is spent: the fee goes to the paymaster and the rest to `recipient`.
///
/// The operation's sender must be the withdrawal's recipient. Nothing in a
/// proof commits to the operation carrying it, so without that the data in
/// `paymasterAndData` would be a bearer instrument: anyone could lift it from
/// the mempool, wrap it in an operation of their own with no calls, and have
/// the victim's note sponsor it, choosing a `postOpGasLimit` that leaves the
/// refund at zero. Requiring the recipient to be the sender means a replayer
/// would have to sign as the recipient's own account. `BasePrivacyPaymaster`
/// allows another sender when the operation makes no calls, which is why this
/// paymaster checks the stricter condition itself rather than using
/// `_requireSenderIsRecipientOrNoCalls`.
///
/// ETH pools only, so fees are never priced and the oracle is not used.
contract TacitPaymaster is BasePrivacyPaymaster {
    struct PaymasterData {
        ITacitPool pool;
        uint256[2] pA;
        uint256[2][2] pB;
        uint256[2] pC;
        uint256[11] publicInputs;
        address payable recipient;
        int256 extAmount;
        uint256 fee;
    }

    /// Index of `outLeaf0` and `outLeaf1` in the pool's public inputs.
    uint256 internal constant OUT_LEAF_0 = 9;
    uint256 internal constant OUT_LEAF_1 = 10;

    // ----- ERRORS -----
    error PoolNotAllowed(address pool);
    error NotAnEthPool(address pool);
    error NotAWithdrawal(int256 extAmount);
    error InsertsLeaves();
    error FeeNotPaid(uint256 expected, uint256 received);
    error SenderIsNotRecipient(address sender, address recipient);
    error BadRecipient();
    error ZeroOwner();

    // ----- STATE -----
    mapping(ITacitPool => bool) public pools;

    // ----- EVENTS -----
    event PoolSet(address indexed pool, bool allowed);

    /// @param owner_ The owner, rather than the deployer. A Tacit proof binds the relayer it was made
    ///        for, so clients are configured with this paymaster's address; taking the owner as an
    ///        argument lets the same address be deployed on several chains through a CREATE3 factory,
    ///        whose ephemeral proxy would otherwise end up owning it.
    constructor(IEntryPoint _entryPoint, IUniswapV3Factory _factory, address _weth, uint32 _twapPeriod, address owner_)
        BasePrivacyPaymaster(_entryPoint, _factory, _weth, _twapPeriod)
    {
        if (owner_ == address(0)) revert ZeroOwner();
        if (owner_ != msg.sender) _transferOwnership(owner_);
    }

    // ----- ADMIN -----

    /// Allows or disallows a Tacit pool. Only native ETH pools can be allowed.
    function setPool(
        ITacitPool pool,
        bool allowed
        // aderyn-ignore-next-line(centralization-risk)
    )
        external
        onlyOwner
    {
        if (allowed && pool.ASSET() != address(0)) revert NotAnEthPool(address(pool));
        pools[pool] = allowed;
        emit PoolSet(address(pool), allowed);
    }

    // ----- BasePrivacyPaymaster -----

    /// Withdraws from the pool with this paymaster as the relayer.
    function _collectFee(PackedUserOperation calldata userOp)
        internal
        override
        returns (address feeToken, uint256 feePaid, address refundRecipient)
    {
        PaymasterData memory d = abi.decode(_paymasterData(userOp), (PaymasterData));
        // Only allowlisted pools are trusted to pay the fee.
        if (!pools[d.pool]) revert PoolNotAllowed(address(d.pool));
        if (d.extAmount >= 0) revert NotAWithdrawal(d.extAmount);
        if (d.publicInputs[OUT_LEAF_0] != 0 || d.publicInputs[OUT_LEAF_1] != 0) revert InsertsLeaves();
        if (userOp.sender != d.recipient) revert SenderIsNotRecipient(userOp.sender, d.recipient);
        // Withdrawing to this paymaster would pay it the whole note and leave nothing to refund.
        if (d.recipient == address(this)) revert BadRecipient();

        uint256 balanceBefore = address(this).balance;
        d.pool.transact(d.pA, d.pB, d.pC, d.publicInputs, d.recipient, d.extAmount, address(this), d.fee, "", "");
        // The fee backs the gas this operation will use, so check it arrived rather than trusting the call.
        uint256 received = address(this).balance - balanceBefore;
        if (received < d.fee) revert FeeNotPaid(d.fee, received);

        // The declared fee, not the balance change: anything beyond it is not this operation's to
        // refund, and counting it would let a recipient that sends ETH back inflate the refund.
        return (address(0), d.fee, d.recipient);
    }
}
