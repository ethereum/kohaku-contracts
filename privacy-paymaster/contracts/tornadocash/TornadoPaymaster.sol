// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    PackedUserOperation
} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {BasePrivacyPaymaster} from "../BasePrivacyPaymaster.sol";
import {ITornadoInstance} from "./interfaces/ITornadoInstance.sol";

/// Paymaster for Tornado Cash withdrawals from any allowlisted ETH instance.
///
/// The paymaster acts as the withdrawal's relayer, so the instance pays the
/// fee directly to it. The proof binds `relayer` and `refund`, so proofs for
/// this paymaster must be generated with `relayer = address(this)` and
/// `refund = 0`.
contract TornadoPaymaster is BasePrivacyPaymaster {
    struct PaymasterData {
        ITornadoInstance instance;
        bytes proof;
        bytes32 root;
        bytes32 nullifierHash;
        address payable recipient;
        uint256 fee;
    }

    // ----- ERRORS -----
    error InstanceNotAllowed(address instance);
    error NotEthInstance(address instance);

    // ----- STATE -----
    mapping(ITornadoInstance => bool) public instances;

    // ----- EVENTS -----
    event InstanceSet(address indexed instance, bool allowed);

    constructor(IEntryPoint _entryPoint) BasePrivacyPaymaster(_entryPoint) {}

    // ----- ADMIN -----
    function setInstance(
        ITornadoInstance instance,
        bool allowed
        // aderyn-ignore-next-line(centralization-risk)
    ) external onlyOwner {
        if (allowed && _isERC20Instance(instance)) {
            revert NotEthInstance(address(instance));
        }
        instances[instance] = allowed;
        emit InstanceSet(address(instance), allowed);
    }

    // ----- BasePrivacyPaymaster -----
    function _collectFee(
        PackedUserOperation calldata userOp
    ) internal override returns (uint256, address) {
        PaymasterData memory d = abi.decode(
            _paymasterData(userOp),
            (PaymasterData)
        );
        // Only allowlisted instances are trusted to actually pay the fee.
        if (!instances[d.instance]) revert InstanceNotAllowed(address(d.instance));
        _checkCallGasLimit(userOp, d.recipient);

        d.instance.withdraw(
            d.proof,
            d.root,
            d.nullifierHash,
            d.recipient,
            payable(address(this)),
            d.fee,
            0
        );
        return (d.fee, d.recipient);
    }

    /// ERC20Tornado exposes a `token()` getter, ETHTornado does not.
    function _isERC20Instance(
        ITornadoInstance instance
    ) internal view returns (bool) {
        (bool ok, bytes memory ret) = address(instance).staticcall(
            abi.encodeWithSignature("token()")
        );
        return ok && ret.length == 32;
    }
}
