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
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {
    IUniswapV3Factory
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {
    OracleLibrary
} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

/// Base paymaster for sponsoring withdrawals from privacy protocols.
///
/// Operations are paid for with the user's shielded funds. During validation
/// the protocol-specific `_collectFee` executes the withdrawal, which pays a
/// fee to this paymaster. Any fee in excess of the operation's actual cost is
/// refunded in `postOp`.
///
/// NOTE: Quoting ERC20 fee tokens reads a Uniswap V3 TWAP, which uses the
/// TIMESTAMP opcode during validation. ERC-7562 (OP-011) bans this, so ERC20
/// fee tokens only work with bundlers that relax that rule. ETH and WETH fees
/// don't touch the oracle.
abstract contract BasePrivacyPaymaster is BasePaymaster {
    using SafeERC20 for IERC20;
    using UserOperationLib for PackedUserOperation;

    struct PostOpContext {
        address feeToken;
        uint256 feePaid;
        address refundRecipient;
        uint256 maxCost;
        uint256 maxCostInToken;
        uint256 postOpGasLimit;
    }

    uint256 internal constant BPS = 10_000;

    /// Slot of the simulation flag, which skips the fee check.
    ///
    /// Never written on-chain. Set it with a state override when estimating
    /// gas. Reading it on every validation keeps gas the same either way.
    bytes32 public constant SIMULATE_SLOT =
        keccak256("privacy-paymaster.simulate");

    // ----- ERRORS -----
    error FeeTokenNotAllowed(address feeToken);
    error InsufficientFee(uint256 required, uint256 fee);
    error CallGasLimitNonZero(uint256 callGasLimit);

    // ----- IMMUTABLES -----
    IUniswapV3Factory public immutable FACTORY;
    address public immutable WETH;
    uint32 public immutable TWAP_PERIOD;

    // ----- STATE -----
    /// Markup charged on top of the quoted gas cost, in basis points.
    uint256 public markupBps;
    /// The Uniswap V3 pool (vs WETH) used to price each allowed ERC20 fee
    /// token. ETH and WETH are always allowed and need no pool.
    mapping(address => address) public oraclePools;

    // ----- EVENTS -----
    event FeeTokenSet(address indexed token, bool allowed);
    event MarkupSet(uint256 markupBps);
    event RefundFailed(
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    // ----- CONSTRUCTOR -----
    constructor(
        IEntryPoint _entryPoint,
        IUniswapV3Factory _factory,
        address _weth,
        uint32 _twapPeriod
    ) BasePaymaster(_entryPoint) {
        FACTORY = _factory;
        WETH = _weth;
        TWAP_PERIOD = _twapPeriod;
    }

    receive() external payable {}

    // ----- ADMIN -----

    /// Sets the markup charged on top of the gas cost.
    function setMarkup(
        uint256 _markupBps
        // aderyn-ignore-next-line(centralization-risk)
    ) external onlyOwner {
        markupBps = _markupBps;
        emit MarkupSet(_markupBps);
    }

    /// Allows or disallows an ERC20 as a fee token.
    ///
    /// @param uniswapFee Fee tier of the token's Uniswap V3 pool with WETH,
    ///        used for pricing. Ignored when disallowing.
    function setFeeToken(
        address token,
        uint24 uniswapFee,
        bool allowed
        // aderyn-ignore-next-line(centralization-risk)
    ) external onlyOwner {
        address pool;
        if (allowed) {
            // aderyn-ignore-next-line reentrancy
            pool = FACTORY.getPool(token, WETH, uniswapFee);
            require(pool != address(0), "pool not supported");
        }
        oraclePools[token] = pool;
        emit FeeTokenSet(token, allowed);
    }

    /// Sends this contract's ETH balance to `to`.
    ///
    /// Doesn't touch the EntryPoint deposit; use `withdrawTo` for that.
    // aderyn-ignore-next-line(centralization-risk)
    function sweep(address payable to) external onlyOwner {
        (bool ok, ) = to.call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }

    /// Sends this contract's balance of `token` to `to`.
    // aderyn-ignore-next-line(centralization-risk)
    function sweepERC20(IERC20 token, address to) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(to, balance);
    }

    // ----- BasePaymaster -----

    /// Collects the fee and checks it covers `maxCost` plus markup.
    ///
    /// Returns an empty context when there's nothing to refund.
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) internal override returns (bytes memory context, uint256 validationData) {
        (
            address feeToken,
            uint256 feePaid,
            address refundRecipient
        ) = _collectFee(userOp);

        uint256 maxCostInToken = quoteWeiInToken(feeToken, maxCost);
        bool simulate = StorageSlot.getBooleanSlot(SIMULATE_SLOT).value;
        if (feePaid < maxCostInToken && !simulate) {
            revert InsufficientFee(maxCostInToken, feePaid);
        }

        // Nothing to refund against when gas is free.
        if (refundRecipient == address(0) || maxCost == 0) return ("", 0);

        context = abi.encode(
            PostOpContext({
                feeToken: feeToken,
                feePaid: feePaid,
                refundRecipient: refundRecipient,
                maxCost: maxCost,
                maxCostInToken: maxCostInToken,
                postOpGasLimit: userOp.unpackPostOpGasLimit()
            })
        );
        return (context, 0);
    }

    /// Refunds the unused part of the fee.
    ///
    /// `actualGasCost` excludes postOp's own gas and unused-gas penalty, so
    /// the full `postOpGasLimit` is charged to cover both.
    function _postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        PostOpContext memory ctx = abi.decode(context, (PostOpContext));
        uint256 gasCost = actualGasCost +
            ctx.postOpGasLimit *
            actualUserOpFeePerGas;
        uint256 refund = _refundAmount(ctx, gasCost);
        if (refund == 0) return;

        if (!_trySafeTransfer(ctx.feeToken, ctx.refundRecipient, refund)) {
            emit RefundFailed(ctx.refundRecipient, ctx.feeToken, refund);
        }
    }

    /// Quotes `weiAmount` in `feeToken`, including the markup.
    ///
    /// ETH and WETH are 1:1. Other tokens use their Uniswap V3 TWAP and
    /// revert unless allowed.
    function quoteWeiInToken(
        address feeToken,
        uint256 weiAmount
    ) public view returns (uint256 tokenAmount) {
        uint256 amount = (weiAmount * (BPS + markupBps)) / BPS;
        if (feeToken == address(0) || feeToken == WETH) return amount;

        address pool = oraclePools[feeToken];
        if (pool == address(0)) revert FeeTokenNotAllowed(feeToken);

        (int24 meanTick, ) = OracleLibrary.consult(pool, TWAP_PERIOD);
        return
            OracleLibrary.getQuoteAtTick(
                meanTick,
                SafeCast.toUint128(amount),
                WETH,
                feeToken
            );
    }

    // ----- PROTOCOL HOOKS -----

    /// Executes the protocol withdrawal, which pays this paymaster's fee.
    ///
    /// `feeToken` is address(0) for ETH. `refundRecipient` is address(0) for
    /// no refund.
    ///
    /// @dev Must revert unless the fee has been paid.
    function _collectFee(
        PackedUserOperation calldata userOp
    )
        internal
        virtual
        returns (address feeToken, uint256 feePaid, address refundRecipient);

    // ----- HELPERS -----

    /// Returns the protocol-specific part of `paymasterAndData`.
    function _paymasterData(
        PackedUserOperation calldata userOp
    ) internal pure returns (bytes calldata) {
        return userOp.paymasterAndData[UserOperationLib.PAYMASTER_DATA_OFFSET:];
    }

    /// Reverts if the op makes calls but isn't the withdrawal's recipient.
    ///
    /// Stops third parties attaching expensive calls to someone else's
    /// withdrawal. Recipients may still make calls, e.g. to swap.
    function _requireSenderIsRecipientOrNoCalls(
        PackedUserOperation calldata userOp,
        address recipient
    ) internal pure {
        uint256 callGasLimit = userOp.unpackCallGasLimit();
        if (recipient != userOp.sender && callGasLimit != 0) {
            revert CallGasLimitNonZero(callGasLimit);
        }
    }

    /// Transfers `token` (address(0) for ETH), returning false on failure.
    function _trySafeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal returns (bool ok) {
        if (token == address(0)) {
            (ok, ) = to.call{value: amount}("");
            return ok;
        }
        return IERC20(token).trySafeTransfer(to, amount);
    }

    /// Returns the part of the fee not needed to cover `gasCost`.
    ///
    /// Prices `gasCost` at the validation-time rate, rounding up.
    function _refundAmount(
        PostOpContext memory ctx,
        uint256 gasCost
    ) internal pure returns (uint256 refund) {
        uint256 cost = Math.mulDiv(
            gasCost,
            ctx.maxCostInToken,
            ctx.maxCost,
            Math.Rounding.Ceil
        );
        return ctx.feePaid > cost ? ctx.feePaid - cost : 0;
    }
}
