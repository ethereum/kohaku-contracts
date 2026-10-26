// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BasePrivacyPaymaster} from "../contracts/BasePrivacyPaymaster.sol";
import {MockPaymaster, MockERC20, RejectEther} from "./mocks/Mocks.sol";

contract BasePrivacyPaymasterTest is Test {
    EntryPoint internal entryPoint;
    MockPaymaster internal paymaster;

    address internal sender = address(0x5EDE2);
    address internal recipient = address(0xECE1);
    address internal notOwner = address(0xBAD);

    function setUp() public {
        entryPoint = new EntryPoint();
        paymaster = new MockPaymaster(IEntryPoint(address(entryPoint)));
    }

    // ----- Helpers -----

    function _buildUserOp() internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000));
    }

    function _validate(uint256 maxCost) internal returns (bytes memory ctx) {
        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(_buildUserOp(), bytes32(0), maxCost);
    }

    function _postOp(bytes memory ctx, uint256 actualGasCost, uint256 feePerGas) internal {
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, actualGasCost, feePerGas);
    }

    // ----- Admin -----

    function test_setMarkup() public {
        vm.expectEmit(false, false, false, true);
        emit BasePrivacyPaymaster.MarkupSet(500);
        paymaster.setMarkup(500);
        assertEq(paymaster.markupBps(), 500);
    }

    function test_admin_rejectsNonOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner);

        vm.startPrank(notOwner);
        vm.expectRevert(err);
        paymaster.setMarkup(1);
        vm.expectRevert(err);
        paymaster.sweep(payable(notOwner));
        vm.expectRevert(err);
        paymaster.sweepERC20(IERC20(address(0)), notOwner);
        vm.stopPrank();
    }

    function test_sweep() public {
        vm.deal(address(paymaster), 1 ether);
        paymaster.sweep(payable(recipient));
        assertEq(recipient.balance, 1 ether);
    }

    function test_sweepERC20() public {
        MockERC20 token = new MockERC20();
        token.mint(address(paymaster), 1 ether);
        paymaster.sweepERC20(IERC20(address(token)), recipient);
        assertEq(token.balanceOf(recipient), 1 ether);
    }

    // ----- Quoting -----

    function test_quoteFee_noMarkup() public view {
        assertEq(paymaster.quoteFee(1 ether), 1 ether);
    }

    function test_quoteFee_appliesMarkupRoundingUp() public {
        paymaster.setMarkup(1_000); // 10%
        assertEq(paymaster.quoteFee(1 ether), 1.1 ether);
        assertEq(paymaster.quoteFee(1), 2);
    }

    // ----- Validation -----

    function test_validate_insufficientFee() public {
        paymaster.setFee(0.1 ether, address(0));

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.5 ether, 0.1 ether));
        _validate(0.5 ether);
    }

    function test_validate_insufficientFeeWithMarkup() public {
        paymaster.setMarkup(1_000); // 10%
        paymaster.setFee(0.5 ether, address(0));

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.55 ether, 0.5 ether));
        _validate(0.5 ether);
    }

    function test_validate_noContextWithoutRefundRecipient() public {
        paymaster.setFee(1 ether, address(0));
        assertEq(_validate(0.5 ether).length, 0);
    }

    function test_validate_returnsContext() public {
        paymaster.setFee(1 ether, recipient);
        BasePrivacyPaymaster.PostOpContext memory ctx =
            abi.decode(_validate(0.5 ether), (BasePrivacyPaymaster.PostOpContext));

        assertEq(ctx.feePaid, 1 ether);
        assertEq(ctx.refundRecipient, recipient);
        assertEq(ctx.postOpGasLimit, 50_000);
    }

    function test_validate_rejectsNonEntryPoint() public {
        vm.expectRevert("Sender not EntryPoint");
        paymaster.validatePaymasterUserOp(_buildUserOp(), bytes32(0), 0);
    }

    // ----- postOp -----

    function test_postOp_refundsExcess() public {
        paymaster.setFee(1 ether, recipient);
        vm.deal(address(paymaster), 1 ether);

        _postOp(_validate(0.5 ether), 0.2 ether, 0);

        assertEq(recipient.balance, 0.8 ether);
        assertEq(address(paymaster).balance, 0.2 ether);
    }

    function test_postOp_chargesPostOpGasLimit() public {
        paymaster.setFee(1 ether, recipient);
        vm.deal(address(paymaster), 1 ether);

        // 0.2 ether actual cost + 50_000 postOpGasLimit * 1 gwei
        _postOp(_validate(0.5 ether), 0.2 ether, 1 gwei);

        assertEq(recipient.balance, 0.79995 ether);
    }

    function test_postOp_chargesMarkup() public {
        paymaster.setMarkup(1_000); // 10%
        paymaster.setFee(1 ether, recipient);
        vm.deal(address(paymaster), 1 ether);

        _postOp(_validate(0.5 ether), 0.2 ether, 0);

        assertEq(recipient.balance, 0.78 ether);
    }

    function test_postOp_noRefundWhenCostCoversFee() public {
        paymaster.setFee(1 ether, recipient);
        vm.deal(address(paymaster), 1 ether);

        _postOp(_validate(1 ether), 1 ether, 0);

        assertEq(recipient.balance, 0);
        assertEq(address(paymaster).balance, 1 ether);
    }

    function test_postOp_refundFailureEmitsEvent() public {
        address rejecter = address(new RejectEther());
        paymaster.setFee(1 ether, rejecter);
        vm.deal(address(paymaster), 1 ether);
        bytes memory ctx = _validate(0.5 ether);

        vm.expectEmit(true, false, false, true);
        emit BasePrivacyPaymaster.RefundFailed(rejecter, 0.8 ether);
        _postOp(ctx, 0.2 ether, 0);

        assertEq(address(paymaster).balance, 1 ether);
    }

    function test_postOp_rejectsNonEntryPoint() public {
        vm.expectRevert("Sender not EntryPoint");
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0, 0);
    }
}
