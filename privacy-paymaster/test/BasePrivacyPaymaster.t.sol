// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {BasePrivacyPaymaster} from "../contracts/BasePrivacyPaymaster.sol";
import {MockPaymaster, MockFactory, MockERC20, RejectEther} from "./mocks/Mocks.sol";

contract BasePrivacyPaymasterTest is Test {
    EntryPoint internal entryPoint;
    MockFactory internal factory;
    MockERC20 internal weth;
    MockPaymaster internal paymaster;

    address internal constant SENDER = address(0x5EDE2);
    address internal constant RECIPIENT = address(0xECE1);
    address internal constant NOT_OWNER = address(0xBAD);

    function setUp() public {
        entryPoint = new EntryPoint();
        factory = new MockFactory();
        weth = new MockERC20();
        paymaster = new MockPaymaster(
            IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(factory)), address(weth), 300
        );
    }

    // ----- Helpers -----

    function _buildUserOp() internal view returns (PackedUserOperation memory op) {
        op.sender = SENDER;
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000));
    }

    function _validate(uint256 maxCost) internal returns (bytes memory ctx) {
        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(_buildUserOp(), bytes32(0), maxCost);
    }

    function _postOp(bytes memory ctx, uint256 actualGasCost) internal {
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, actualGasCost, 0);
    }

    // ----- Constructor -----

    function test_constructor() public view {
        assertEq(paymaster.TWAP_PERIOD(), 300);
        assertEq(paymaster.markupBps(), 0);
    }

    // ----- Admin -----

    function test_admin_rejectsNonOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NOT_OWNER);

        vm.startPrank(NOT_OWNER);
        vm.expectRevert(err);
        paymaster.setFeeToken(address(weth), 3000, true);
        vm.expectRevert(err);
        paymaster.setMarkup(1);
        vm.expectRevert(err);
        paymaster.sweep(payable(NOT_OWNER));
        vm.expectRevert(err);
        paymaster.sweepERC20(IERC20(address(weth)), NOT_OWNER);
        vm.stopPrank();
    }

    function test_setFeeToken_erc20() public {
        MockERC20 token = new MockERC20();
        factory.setPool(address(token), address(weth), 3000, address(0x1234));

        paymaster.setFeeToken(address(token), 3000, true);

        assertEq(paymaster.oraclePools(address(token)), address(0x1234));
    }

    function test_setFeeToken_revertsIfPoolMissing() public {
        address token = address(new MockERC20());
        vm.expectRevert("pool not supported");
        paymaster.setFeeToken(token, 3000, true);
    }

    function test_setFeeToken_disallow() public {
        MockERC20 token = new MockERC20();
        factory.setPool(address(token), address(weth), 3000, address(0x1234));
        paymaster.setFeeToken(address(token), 3000, true);

        paymaster.setFeeToken(address(token), 3000, false);
        assertEq(paymaster.oraclePools(address(token)), address(0));
    }

    function test_setMarkup() public {
        vm.expectEmit(false, false, false, true);
        emit BasePrivacyPaymaster.MarkupSet(500);
        paymaster.setMarkup(500);
        assertEq(paymaster.markupBps(), 500);
    }

    function test_sweep() public {
        vm.deal(address(paymaster), 1 ether);
        paymaster.sweep(payable(RECIPIENT));
        assertEq(RECIPIENT.balance, 1 ether);
    }

    function test_sweepERC20() public {
        weth.mint(address(paymaster), 1 ether);
        paymaster.sweepERC20(IERC20(address(weth)), RECIPIENT);
        assertEq(weth.balanceOf(RECIPIENT), 1 ether);
    }

    // ----- Quoting -----

    function test_quoteWeiInToken_ethAndWethAreOneToOne() public view {
        assertEq(paymaster.quoteWeiInToken(address(0), 1 ether), 1 ether);
        assertEq(paymaster.quoteWeiInToken(address(weth), 1 ether), 1 ether);
    }

    function test_quoteWeiInToken_appliesMarkup() public {
        paymaster.setMarkup(1_000); // 10%
        assertEq(paymaster.quoteWeiInToken(address(0), 1 ether), 1.1 ether);
    }

    // ----- Validation -----

    function test_validate_feeTokenNotAllowed() public {
        address token = address(new MockERC20());
        paymaster.setFee(token, 1 ether, address(0));

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.FeeTokenNotAllowed.selector, token));
        _validate(0.5 ether);
    }

    function test_validate_insufficientFee() public {
        paymaster.setFee(address(0), 0.1 ether, address(0));

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.5 ether, 0.1 ether));
        _validate(0.5 ether);
    }

    function test_validate_insufficientFeeWithMarkup() public {
        paymaster.setMarkup(1_000); // 10%
        paymaster.setFee(address(0), 0.5 ether, address(0));

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.55 ether, 0.5 ether));
        _validate(0.5 ether);
    }

    function test_validate_noContextWithoutRefundRecipient() public {
        paymaster.setFee(address(0), 1 ether, address(0));
        assertEq(_validate(0.5 ether).length, 0);
    }

    function test_validate_noContextWhenGasIsFree() public {
        paymaster.setFee(address(0), 1 ether, RECIPIENT);
        assertEq(_validate(0).length, 0);
    }

    function test_validate_returnsContext() public {
        paymaster.setFee(address(0), 1 ether, RECIPIENT);
        BasePrivacyPaymaster.PostOpContext memory ctx =
            abi.decode(_validate(0.5 ether), (BasePrivacyPaymaster.PostOpContext));

        assertEq(ctx.feeToken, address(0));
        assertEq(ctx.feePaid, 1 ether);
        assertEq(ctx.refundRecipient, RECIPIENT);
        assertEq(ctx.maxCost, 0.5 ether);
        assertEq(ctx.maxCostInToken, 0.5 ether);
    }

    function test_validate_rejectsNonEntryPoint() public {
        vm.expectRevert("Sender not EntryPoint");
        paymaster.validatePaymasterUserOp(_buildUserOp(), bytes32(0), 0);
    }

    // ----- postOp -----

    function test_postOp_refundsExcessEth() public {
        paymaster.setFee(address(0), 1 ether, RECIPIENT);
        vm.deal(address(paymaster), 1 ether);

        _postOp(_validate(0.5 ether), 0.2 ether);

        assertEq(RECIPIENT.balance, 0.8 ether);
        assertEq(address(paymaster).balance, 0.2 ether);
    }

    function test_postOp_refundsExcessWeth() public {
        paymaster.setFee(address(weth), 1 ether, RECIPIENT);
        weth.mint(address(paymaster), 1 ether);

        _postOp(_validate(0.5 ether), 0.2 ether);

        assertEq(weth.balanceOf(RECIPIENT), 0.8 ether);
        assertEq(weth.balanceOf(address(paymaster)), 0.2 ether);
    }

    function test_postOp_chargesPostOpGasLimit() public {
        paymaster.setFee(address(0), 1 ether, RECIPIENT);
        vm.deal(address(paymaster), 1 ether);
        bytes memory ctx = _validate(0.5 ether);

        // 0.2 ether actual cost + 50_000 postOpGasLimit * 1 gwei
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.2 ether, 1 gwei);

        assertEq(RECIPIENT.balance, 0.79995 ether);
    }

    function test_postOp_noRefundWhenCostEqualsFee() public {
        paymaster.setFee(address(0), 1 ether, RECIPIENT);
        vm.deal(address(paymaster), 1 ether);

        _postOp(_validate(1 ether), 1 ether);

        assertEq(RECIPIENT.balance, 0);
        assertEq(address(paymaster).balance, 1 ether);
    }

    function test_postOp_refundFailureEmitsEvent() public {
        address rejecter = address(new RejectEther());
        paymaster.setFee(address(0), 1 ether, rejecter);
        vm.deal(address(paymaster), 1 ether);
        bytes memory ctx = _validate(0.5 ether);

        vm.expectEmit(true, true, false, true);
        emit BasePrivacyPaymaster.RefundFailed(rejecter, address(0), 0.8 ether);
        _postOp(ctx, 0.2 ether);

        assertEq(address(paymaster).balance, 1 ether);
    }

    function test_postOp_rejectsNonEntryPoint() public {
        vm.expectRevert("Sender not EntryPoint");
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0, 0);
    }

    // ----- _refundAmount -----

    function testFuzz_refundAmount_neverExceedsFee(
        uint128 feePaid,
        uint128 maxCost,
        uint128 maxCostInToken,
        uint128 gasCost
    ) public view {
        vm.assume(maxCost > 0);
        BasePrivacyPaymaster.PostOpContext memory ctx = BasePrivacyPaymaster.PostOpContext({
            feeToken: address(0),
            feePaid: feePaid,
            refundRecipient: RECIPIENT,
            maxCost: maxCost,
            maxCostInToken: maxCostInToken,
            postOpGasLimit: 0
        });
        assertLe(paymaster.refundAmount(ctx, gasCost), feePaid);
    }
}
