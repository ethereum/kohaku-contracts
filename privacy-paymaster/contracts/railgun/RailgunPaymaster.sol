// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {BasePrivacyPaymaster} from "../BasePrivacyPaymaster.sol";
import {IRailgunSmartWallet} from "./interfaces/IRailgunSmartWallet.sol";
import {Transaction, CommitmentPreimage, TokenData, TokenType} from "./Globals.sol";

/// Paymaster for Railgun transactions.
///
/// The fee is paid as a shielded transfer to the paymaster's railgun wallet,
/// so it can't be refunded.
contract RailgunPaymaster is BasePrivacyPaymaster {
    struct PaymasterData {
        bytes16 random;
        address asset;
        uint120 value;
        Transaction[] transactions;
    }

    // ----- ERRORS -----
    error AdaptParamsAreNotSender(bytes32 adaptParams, bytes32 sender);
    error MissingFee(bytes32 masterPublicKey, bytes16 random, address asset, uint120 value);

    // ----- IMMUTABLES -----
    IRailgunSmartWallet public immutable RAILGUN_SMART_WALLET;
    /// The MPK for the paymaster's zk-wallet.
    bytes32 immutable MASTER_PUBLIC_KEY;

    constructor(
        IEntryPoint _entryPoint,
        IUniswapV3Factory _factory,
        address _weth,
        uint32 _twapPeriod,
        IRailgunSmartWallet _railgunSmartWallet,
        bytes32 _masterPublicKey
    ) BasePrivacyPaymaster(_entryPoint, _factory, _weth, _twapPeriod) {
        RAILGUN_SMART_WALLET = _railgunSmartWallet;
        MASTER_PUBLIC_KEY = _masterPublicKey;
    }

    // ----- BasePrivacyPaymaster -----

    /// Executes the Railgun transactions, one of which pays this paymaster.
    ///
    /// The fee is shielded, so it can't be refunded.
    function _collectFee(PackedUserOperation calldata userOp)
        internal
        override
        returns (address feeToken, uint256 feePaid, address refundRecipient)
    {
        PaymasterData memory d = abi.decode(_paymasterData(userOp), (PaymasterData));
        _verifyTransactions(userOp.sender, d);
        RAILGUN_SMART_WALLET.transact(d.transactions);

        return (d.asset, d.value, address(0));
    }

    /// Reverts unless the transactions are bound to `sender` and pay the fee.
    ///
    /// Binding `adaptParams` to the sender stops others submitting them.
    function _verifyTransactions(address sender, PaymasterData memory d) internal view {
        bytes32 expectedCommitment = _hashCommitment(d.random, d.asset, d.value);

        bool commitmentFound = false;
        for (uint256 i = 0; i < d.transactions.length; i++) {
            Transaction memory t = d.transactions[i];
            if (t.boundParams.adaptParams != bytes32(uint256(uint160(sender)))) {
                revert AdaptParamsAreNotSender(t.boundParams.adaptParams, bytes32(uint256(uint160(sender))));
            }

            for (uint256 j = 0; j < t.commitments.length; j++) {
                if (t.commitments[j] == expectedCommitment) {
                    commitmentFound = true;
                }
            }
        }

        if (!commitmentFound) {
            revert MissingFee(MASTER_PUBLIC_KEY, d.random, d.asset, d.value);
        }
    }

    /// Returns the commitment for a fee transfer to this paymaster.
    function _hashCommitment(bytes16 random, address asset, uint120 value) internal view returns (bytes32) {
        bytes32 npk = RAILGUN_SMART_WALLET.hashLeftRight(MASTER_PUBLIC_KEY, bytes32(uint256(uint128(random))));

        CommitmentPreimage memory commitmentPreimage = CommitmentPreimage({
            npk: npk, token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}), value: value
        });

        return RAILGUN_SMART_WALLET.hashCommitment(commitmentPreimage);
    }
}
