// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    PackedUserOperation
} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {
    IUniswapV3Factory
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {BasePrivacyPaymaster} from "../BasePrivacyPaymaster.sol";
import {ITornadoInstance} from "./interfaces/ITornadoInstance.sol";

/// Paymaster for Tornado Cash withdrawals from any allowlisted instance.
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

    struct Instance {
        bool allowed;
        /// The instance's ERC20, or address(0) for ETH instances.
        address token;
    }

    // ----- ERRORS -----
    error InstanceNotAllowed(address instance);

    // ----- STATE -----
    mapping(ITornadoInstance => Instance) public instances;

    // ----- EVENTS -----
    event InstanceSet(address indexed instance, bool allowed);

    constructor(
        IEntryPoint _entryPoint,
        IUniswapV3Factory _factory,
        address _weth,
        uint32 _twapPeriod
    ) BasePrivacyPaymaster(_entryPoint, _factory, _weth, _twapPeriod) {}

    // ----- ADMIN -----

    /// Allows or disallows a Tornado instance.
    function setInstance(
        ITornadoInstance instance,
        bool allowed
        // aderyn-ignore-next-line(centralization-risk)
    ) external onlyOwner {
        instances[instance] = Instance({
            allowed: allowed,
            token: _instanceToken(instance)
        });
        emit InstanceSet(address(instance), allowed);
    }

    // ----- BasePrivacyPaymaster -----

    /// Withdraws from the instance with this paymaster as the relayer.
    function _collectFee(
        PackedUserOperation calldata userOp
    )
        internal
        override
        returns (address feeToken, uint256 feePaid, address refundRecipient)
    {
        PaymasterData memory d = abi.decode(
            _paymasterData(userOp),
            (PaymasterData)
        );
        // Only allowlisted instances are trusted to actually pay the fee.
        Instance memory instance = instances[d.instance];
        if (!instance.allowed) revert InstanceNotAllowed(address(d.instance));
        _requireSenderIsRecipientOrNoCalls(userOp, d.recipient);

        d.instance.withdraw(
            d.proof,
            d.root,
            d.nullifierHash,
            d.recipient,
            payable(address(this)),
            d.fee,
            0
        );
        return (instance.token, d.fee, d.recipient);
    }

    /// Returns the instance's ERC20, or address(0) for ETH instances.
    ///
    /// Only ERC20Tornado has a `token()` getter.
    function _instanceToken(
        ITornadoInstance instance
    ) internal view returns (address) {
        (bool ok, bytes memory ret) = address(instance).staticcall(
            abi.encodeWithSignature("token()")
        );
        if (ok && ret.length == 32) {
            return abi.decode(ret, (address));
        }
        return address(0);
    }
}
