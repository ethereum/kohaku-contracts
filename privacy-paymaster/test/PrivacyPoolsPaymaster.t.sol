// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {BasePrivacyPaymaster} from "../contracts/BasePrivacyPaymaster.sol";
import {IPrivacyPool} from "../contracts/privacypools/interfaces/IPrivacyPool.sol";
import {PrivacyPoolsPaymaster} from "../contracts/privacypools/PrivacyPoolsPaymaster.sol";
import {MockERC20, MockPrivacyPool} from "./mocks/Mocks.sol";

contract PrivacyPoolsPaymasterTest is Test {
    address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant RECIPIENT = address(0x5A71CE2);
    address internal constant SENDER = address(0x5EDE2);

    EntryPoint internal entryPoint;
    PrivacyPoolsPaymaster internal paymaster;
    MockPrivacyPool internal nativePool;
    MockPrivacyPool internal erc20Pool;
    MockERC20 internal token;

    function setUp() public {
        entryPoint = new EntryPoint();
        // Use the ERC20 as WETH so it's priced 1:1 without an oracle.
        token = new MockERC20();
        paymaster = new PrivacyPoolsPaymaster(
            IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), address(token), 300
        );

        nativePool = new MockPrivacyPool(NATIVE_ASSET);
        erc20Pool = new MockPrivacyPool(address(token));
        paymaster.setPool(nativePool, true);
        paymaster.setPool(erc20Pool, true);
    }

    // ----- Helpers -----

    function _buildUserOp(IPrivacyPool pool, address processooor, uint256 fee, uint256 withdrawnValue)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        return _buildUserOp(
            pool,
            processooor,
            abi.encode(PrivacyPoolsPaymaster.FeeData({recipient: RECIPIENT, fee: fee})),
            withdrawnValue,
            0
        );
    }

    function _buildUserOp(
        IPrivacyPool pool,
        address processooor,
        bytes memory feeData,
        uint256 withdrawnValue,
        uint256 callGasLimit
    ) internal view returns (PackedUserOperation memory op) {
        IPrivacyPool.WithdrawProof memory proof;
        proof.pubSignals[2] = withdrawnValue;
        PrivacyPoolsPaymaster.PaymasterData memory data = PrivacyPoolsPaymaster.PaymasterData({
            pool: pool,
            withdrawal: IPrivacyPool.Withdrawal({processooor: processooor, data: feeData}),
            proof: proof
        });

        op.sender = SENDER;
        op.accountGasLimits = bytes32(callGasLimit);
        op.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(500_000), uint128(50_000), abi.encode(data));
    }

    function _validate(PackedUserOperation memory op, uint256 maxCost) internal returns (bytes memory ctx) {
        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
    }

    // ----- Admin -----

    function test_setPool_normalizesNativeAsset() public view {
        (bool allowed, address asset) = paymaster.pools(nativePool);
        assertTrue(allowed);
        assertEq(asset, address(0));

        (, asset) = paymaster.pools(erc20Pool);
        assertEq(asset, address(token));
    }

    // ----- Validation -----

    function test_valid_native() public {
        vm.deal(address(nativePool), 1 ether);
        bytes memory context = _validate(_buildUserOp(nativePool, address(paymaster), 0.1 ether, 1 ether), 0.05 ether);

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(0));
        assertEq(ctx.feePaid, 0.1 ether);
        assertEq(ctx.refundRecipient, RECIPIENT);
        assertEq(address(paymaster).balance, 0.1 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }

    function test_valid_native_fullSweep() public {
        vm.deal(address(nativePool), 1 ether);
        _validate(_buildUserOp(nativePool, address(paymaster), 1 ether, 1 ether), 0.05 ether);

        assertEq(address(paymaster).balance, 1 ether);
        assertEq(RECIPIENT.balance, 0);
    }

    function test_valid_erc20() public {
        token.mint(address(erc20Pool), 100 ether);
        bytes memory context = _validate(_buildUserOp(erc20Pool, address(paymaster), 5 ether, 100 ether), 1 ether);

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(token));
        assertEq(token.balanceOf(address(paymaster)), 5 ether);
        assertEq(token.balanceOf(RECIPIENT), 95 ether);
    }

    function test_valid_recipientIsSenderAllowsCallGasLimit() public {
        vm.deal(address(nativePool), 1 ether);
        bytes memory feeData = abi.encode(PrivacyPoolsPaymaster.FeeData({recipient: SENDER, fee: 0.1 ether}));
        _validate(_buildUserOp(nativePool, address(paymaster), feeData, 1 ether, 100_000), 0.05 ether);

        assertEq(SENDER.balance, 0.9 ether);
    }

    function test_poolNotAllowed() public {
        MockPrivacyPool other = new MockPrivacyPool(NATIVE_ASSET);
        PackedUserOperation memory op = _buildUserOp(other, address(paymaster), 0.1 ether, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(PrivacyPoolsPaymaster.PoolNotAllowed.selector, address(other)));
        _validate(op, 0.05 ether);
    }

    function test_processooorNotPaymaster() public {
        vm.deal(address(nativePool), 1 ether);
        PackedUserOperation memory op = _buildUserOp(nativePool, address(0xDEAD), 0.1 ether, 1 ether);

        vm.expectRevert(MockPrivacyPool.MockRevert.selector);
        _validate(op, 0.05 ether);
    }

    function test_callGasLimitNonZero() public {
        bytes memory feeData = abi.encode(PrivacyPoolsPaymaster.FeeData({recipient: RECIPIENT, fee: 0.1 ether}));
        PackedUserOperation memory op = _buildUserOp(nativePool, address(paymaster), feeData, 1 ether, 100);

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.CallGasLimitNonZero.selector, 100));
        _validate(op, 0.05 ether);
    }

    function test_feeExceedsWithdrawal() public {
        vm.deal(address(nativePool), 1 ether);
        PackedUserOperation memory op = _buildUserOp(nativePool, address(paymaster), 0.5 ether, 0.1 ether);

        vm.expectRevert(abi.encodeWithSelector(PrivacyPoolsPaymaster.FeeExceedsWithdrawal.selector, 0.5 ether, 0.1 ether));
        _validate(op, 0.05 ether);
    }

    function test_insufficientFee() public {
        vm.deal(address(nativePool), 1 ether);
        PackedUserOperation memory op = _buildUserOp(nativePool, address(paymaster), 0.01 ether, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.1 ether, 0.01 ether));
        _validate(op, 0.1 ether);
    }

    function test_withdrawalFails() public {
        nativePool.setShouldFail(true);
        PackedUserOperation memory op = _buildUserOp(nativePool, address(paymaster), 0.1 ether, 1 ether);

        vm.expectRevert(MockPrivacyPool.MockRevert.selector);
        _validate(op, 0.05 ether);
    }
}
