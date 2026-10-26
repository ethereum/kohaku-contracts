// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    BasePaymaster
} from "@account-abstraction/contracts/core/BasePaymaster.sol";
import {
    UserOperationLib
} from "@account-abstraction/contracts/core/UserOperationLib.sol";
import {
    PackedUserOperation
} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Base paymaster for sponsoring withdrawals from privacy protocols.
///
/// Operations are paid for with the user's shielded funds. During validation
/// the protocol-specific `_collectFee` executes the withdrawal, which pays a
/// fee in ETH (or an ETH equivalent) to this paymaster. Any fee in excess of
/// the operation's actual cost is refunded in `postOp`.
abstract contract BasePrivacyPaymaster is BasePaymaster {
    using SafeERC20 for IERC20;
    using UserOperationLib for PackedUserOperation;

    struct PostOpContext {
        uint256 feePaid;
        address refundRecipient;
        uint256 postOpGasLimit;
    }

    uint256 internal constant BPS = 10_000;

    // ----- ERRORS -----
    error InsufficientFee(uint256 required, uint256 fee);
    error CallGasLimitNonZero(uint256 callGasLimit);

    // ----- STATE -----
    /// Markup charged on top of the gas cost, in basis points.
    uint256 public markupBps;

    // ----- EVENTS -----
    event MarkupSet(uint256 markupBps);
    event RefundFailed(address indexed recipient, uint256 amount);

    // ----- CONSTRUCTOR -----
    constructor(IEntryPoint _entryPoint) BasePaymaster(_entryPoint) {}

    receive() external payable {}

    // ----- ADMIN -----
    function setMarkup(
        uint256 _markupBps
        // aderyn-ignore-next-line(centralization-risk)
    ) external onlyOwner {
        markupBps = _markupBps;
        emit MarkupSet(_markupBps);
    }

    // aderyn-ignore-next-line(centralization-risk)
    function sweep(address payable to) external onlyOwner {
        (bool ok, ) = to.call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }

    // aderyn-ignore-next-line(centralization-risk)
    function sweepERC20(IERC20 token, address to) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(to, balance);
    }

    // ----- BasePaymaster -----
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) internal override returns (bytes memory context, uint256 validationData) {
        (uint256 feePaid, address refundRecipient) = _collectFee(userOp);

        uint256 required = quoteFee(maxCost);
        if (feePaid < required) revert InsufficientFee(required, feePaid);
        if (refundRecipient == address(0)) return ("", 0);

        context = abi.encode(
            PostOpContext({
                feePaid: feePaid,
                refundRecipient: refundRecipient,
                postOpGasLimit: userOp.unpackPostOpGasLimit()
            })
        );
        return (context, 0);
    }

    /// Only called by the EntryPoint when validation returned a context.
    ///
    /// `actualGasCost` excludes this postOp's own gas and its unused-gas
    /// penalty, so the full `postOpGasLimit` is charged on top. That covers
    /// both, since the penalty is at most 10% of the unused limit.
    function _postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        PostOpContext memory ctx = abi.decode(context, (PostOpContext));
        uint256 cost = quoteFee(
            actualGasCost + ctx.postOpGasLimit * actualUserOpFeePerGas
        );
        if (ctx.feePaid <= cost) return;

        uint256 refund = ctx.feePaid - cost;
        (bool ok, ) = ctx.refundRecipient.call{value: refund}("");
        if (!ok) emit RefundFailed(ctx.refundRecipient, refund);
    }

    /// The fee charged for `gasCost` wei of gas, including the markup.
    function quoteFee(uint256 gasCost) public view returns (uint256) {
        return Math.mulDiv(gasCost, BPS + markupBps, BPS, Math.Rounding.Ceil);
    }

    // ----- PROTOCOL HOOKS -----

    /// Executes the protocol withdrawal, which must pay this paymaster's fee.
    ///
    /// @return feePaid The fee paid to this paymaster, in wei.
    /// @return refundRecipient Where excess fees are refunded in ETH in
    ///         postOp, or address(0) for no refund.
    ///
    /// @dev Must revert unless the fee has been paid.
    function _collectFee(
        PackedUserOperation calldata userOp
    ) internal virtual returns (uint256 feePaid, address refundRecipient);

    // ----- HELPERS -----

    /// The protocol-specific data following the paymaster's static fields.
    function _paymasterData(
        PackedUserOperation calldata userOp
    ) internal pure returns (bytes calldata) {
        return userOp.paymasterAndData[UserOperationLib.PAYMASTER_DATA_OFFSET:];
    }

    /// Anti-griefing: either the withdrawal recipient is the userOp sender
    /// (so it may perform secondary actions like a DEX swap), or the op
    /// may not execute any calls. Otherwise a third party could attach
    /// expensive calls to someone else's withdrawal.
    function _checkCallGasLimit(
        PackedUserOperation calldata userOp,
        address recipient
    ) internal pure {
        uint256 callGasLimit = userOp.unpackCallGasLimit();
        if (recipient != userOp.sender && callGasLimit != 0) {
            revert CallGasLimitNonZero(callGasLimit);
        }
    }
}
