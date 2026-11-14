// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {BasePrivacyPaymaster} from "../contracts/BasePrivacyPaymaster.sol";
import {ITacitPool} from "../contracts/tacit/interfaces/ITacitPool.sol";
import {TacitPaymaster} from "../contracts/tacit/TacitPaymaster.sol";
import {
    EagerRecipient,
    MockStingyTacitPool,
    MockTacitPool,
    MockTacitTokenPool,
    OpenAccount
} from "./mocks/TacitMocks.sol";

contract TacitPaymasterTest is Test {
    address internal constant SENDER = address(0x5EDE2);
    address payable internal constant RECIPIENT = payable(address(0x5A71CE2));
    uint256 internal constant NOTE = 1 ether;

    EntryPoint internal entryPoint;
    TacitPaymaster internal paymaster;
    MockTacitPool internal pool;

    function setUp() public {
        entryPoint = new EntryPoint();
        paymaster = new TacitPaymaster(
            IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), address(0), 300, address(this)
        );
        pool = new MockTacitPool();
        vm.deal(address(pool), 10 ether);
        paymaster.setPool(ITacitPool(address(pool)), true);
    }

    // ----- Helpers -----

    function _data(address pool_, int256 extAmount, uint256 fee, uint256 nullifier, uint256 outLeaf0, uint256 outLeaf1)
        internal
        pure
        returns (TacitPaymaster.PaymasterData memory d)
    {
        d.pool = ITacitPool(pool_);
        d.publicInputs[7] = nullifier;
        d.publicInputs[9] = outLeaf0;
        d.publicInputs[10] = outLeaf1;
        d.recipient = RECIPIENT;
        d.extAmount = extAmount;
        d.fee = fee;
    }

    function _op(TacitPaymaster.PaymasterData memory d, address sender, uint256 callGasLimit)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.accountGasLimits = bytes32(callGasLimit);
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(500_000), uint128(50_000), abi.encode(d));
    }

    function _withdrawal(uint256 fee, address sender, uint256 callGasLimit)
        internal
        view
        returns (PackedUserOperation memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        return _op(_data(address(pool), -int256(NOTE - fee), fee, 1, 0, 0), sender, callGasLimit);
    }

    function _validate(PackedUserOperation memory op, uint256 maxCost) internal returns (bytes memory ctx) {
        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
    }

    // ----- Admin -----

    function test_setPool() public {
        ITacitPool other = ITacitPool(address(new MockTacitPool()));

        vm.expectEmit(true, false, false, true);
        emit TacitPaymaster.PoolSet(address(other), true);
        paymaster.setPool(other, true);
        assertTrue(paymaster.pools(other));

        paymaster.setPool(other, false);
        assertFalse(paymaster.pools(other));
    }

    function test_setPool_rejectsTokenPool() public {
        address tokenPool = address(new MockTacitTokenPool());
        vm.expectRevert(abi.encodeWithSelector(TacitPaymaster.NotAnEthPool.selector, tokenPool));
        paymaster.setPool(ITacitPool(tokenPool), true);
    }

    /// A CREATE3 factory's ephemeral proxy is the deployer, so the owner is an argument: without
    /// that, nobody could allowlist a pool, stake the paymaster or withdraw its deposit.
    function test_ownerIsTheArgumentNotTheDeployer() public {
        TacitPaymaster owned = new TacitPaymaster(
            IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), address(0), 300, RECIPIENT
        );

        assertEq(owned.owner(), RECIPIENT);
        vm.prank(RECIPIENT);
        owned.setPool(ITacitPool(address(pool)), true);
        assertTrue(owned.pools(ITacitPool(address(pool))));
    }

    function test_rejectsZeroOwner() public {
        vm.expectRevert(TacitPaymaster.ZeroOwner.selector);
        new TacitPaymaster(IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), address(0), 300, address(0));
    }

    function test_setPool_rejectsNonOwner() public {
        vm.prank(SENDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, SENDER));
        paymaster.setPool(ITacitPool(address(pool)), false);
    }

    // ----- Validation -----

    function test_valid() public {
        bytes memory context = _validate(_withdrawal(0.1 ether, RECIPIENT, 0), 0.05 ether);

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(0));
        assertEq(ctx.feePaid, 0.1 ether);
        assertEq(ctx.refundRecipient, RECIPIENT);
        assertEq(pool.lastRelayer(), address(paymaster));
        assertEq(address(paymaster).balance, 0.1 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }

    /// The recipient spends what it withdrew in the same operation.
    function test_valid_recipientMayMakeCalls() public {
        _validate(_withdrawal(0.1 ether, RECIPIENT, 1_000_000), 0.05 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }

    /// Without this, `paymasterAndData` would be a bearer instrument: anyone could lift it from
    /// the mempool, wrap it in an operation of their own, and have the victim's note sponsor it.
    function test_anotherSenderCannotRideTheProof() public {
        PackedUserOperation memory op = _withdrawal(0.1 ether, SENDER, 0);

        vm.expectRevert(abi.encodeWithSelector(TacitPaymaster.SenderIsNotRecipient.selector, SENDER, RECIPIENT));
        _validate(op, 0.05 ether);
        assertFalse(pool.nullified(1), "the note is untouched");
    }

    function test_rejectsWithdrawalToThePaymaster() public {
        TacitPaymaster.PaymasterData memory d = _data(address(pool), -0.9 ether, 0.1 ether, 1, 0, 0);
        d.recipient = payable(address(paymaster));

        vm.expectRevert(TacitPaymaster.BadRecipient.selector);
        _validate(_op(d, address(paymaster), 0), 0.05 ether);
    }

    /// A recipient that sends ETH back during its payout cannot inflate what the refund is
    /// measured against: the declared fee is what counts.
    function test_feePaidIsTheDeclaredFee() public {
        EagerRecipient eager = new EagerRecipient(payable(address(paymaster)));
        TacitPaymaster.PaymasterData memory d = _data(address(pool), -0.9 ether, 0.1 ether, 1, 0, 0);
        d.recipient = payable(address(eager));

        bytes memory context = _validate(_op(d, address(eager), 0), 0.05 ether);
        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feePaid, 0.1 ether, "the declared fee, not the balance change");
        assertGt(address(paymaster).balance, 0.1 ether, "more ETH did arrive");
    }

    function test_zeroFeeIsRefusedWhenGasCosts() public {
        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.05 ether, 0));
        _validate(_withdrawal(0, RECIPIENT, 0), 0.05 ether);
    }

    function test_poolNotAllowed() public {
        address other = address(new MockTacitPool());
        PackedUserOperation memory op = _op(_data(other, -0.9 ether, 0.1 ether, 1, 0, 0), SENDER, 0);

        vm.expectRevert(abi.encodeWithSelector(TacitPaymaster.PoolNotAllowed.selector, other));
        _validate(op, 0.05 ether);
    }

    function test_poolDisallowed() public {
        paymaster.setPool(ITacitPool(address(pool)), false);
        vm.expectRevert(abi.encodeWithSelector(TacitPaymaster.PoolNotAllowed.selector, address(pool)));
        _validate(_withdrawal(0.1 ether, RECIPIENT, 0), 0.05 ether);
    }

    function test_notAWithdrawal() public {
        PackedUserOperation memory zero = _op(_data(address(pool), 0, 0.1 ether, 1, 0, 0), SENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(TacitPaymaster.NotAWithdrawal.selector, int256(0)));
        _validate(zero, 0.05 ether);

        PackedUserOperation memory deposit = _op(_data(address(pool), 1 ether, 0.1 ether, 1, 0, 0), SENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(TacitPaymaster.NotAWithdrawal.selector, int256(1 ether)));
        _validate(deposit, 0.05 ether);
    }

    function test_rejectsProofsThatInsertLeaves() public {
        // Either output slot: such a proof goes stale when any other transaction reaches the pool.
        PackedUserOperation memory first = _op(_data(address(pool), -0.5 ether, 0.1 ether, 1, 7, 0), SENDER, 0);
        vm.expectRevert(TacitPaymaster.InsertsLeaves.selector);
        _validate(first, 0.05 ether);

        PackedUserOperation memory second = _op(_data(address(pool), -0.5 ether, 0.1 ether, 1, 0, 7), SENDER, 0);
        vm.expectRevert(TacitPaymaster.InsertsLeaves.selector);
        _validate(second, 0.05 ether);
    }

    function test_insufficientFee() public {
        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.1 ether, 0.01 ether));
        _validate(_withdrawal(0.01 ether, RECIPIENT, 0), 0.1 ether);
    }

    function test_insufficientFeeWithMarkup() public {
        paymaster.setMarkup(1_000); // 10%
        // 0.1 ETH of gas needs 0.11 ETH of fee.
        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.11 ether, 0.1 ether));
        _validate(_withdrawal(0.1 ether, RECIPIENT, 0), 0.1 ether);
    }

    function test_nullifierSingleUse() public {
        _validate(_withdrawal(0.1 ether, RECIPIENT, 0), 0.05 ether);
        vm.expectRevert(MockTacitPool.AlreadyNullified.selector);
        _validate(_withdrawal(0.1 ether, RECIPIENT, 0), 0.05 ether);
    }

    function test_feeNotPaid() public {
        MockStingyTacitPool stingy = new MockStingyTacitPool();
        vm.deal(address(stingy), 10 ether);
        paymaster.setPool(ITacitPool(address(stingy)), true);

        PackedUserOperation memory op = _op(_data(address(stingy), -0.9 ether, 0.1 ether, 1, 0, 0), RECIPIENT, 0);
        vm.expectRevert(abi.encodeWithSelector(TacitPaymaster.FeeNotPaid.selector, 0.1 ether, 0));
        _validate(op, 0.05 ether);
    }

    /// The SDK's `encodeTacitPaymasterData` (viem) encodes this sample to exactly these bytes.
    function test_sdkEncodingMatches() public pure {
        TacitPaymaster.PaymasterData memory d;
        d.pool = ITacitPool(0x000000c2A20657CE25f2Ba99737933D031AFBEE9);
        d.pA = [uint256(1), 2];
        d.pB = [[uint256(3), 4], [uint256(5), 6]];
        d.pC = [uint256(7), 8];
        for (uint256 i; i < 9; ++i) {
            d.publicInputs[i] = 10 + i;
        }
        d.recipient = payable(address(0x5A71CE2));
        d.extAmount = -0.9 ether;
        d.fee = 0.1 ether;

        assertEq(
            abi.encode(d),
            hex"000000000000000000000000000000c2a20657ce25f2ba99737933d031afbee900000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000b000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000d000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000f000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000110000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005a71ce2fffffffffffffffffffffffffffffffffffffffffffffffff3828ec4b6260000000000000000000000000000000000000000000000000000016345785d8a0000"
        );
    }

    function test_rejectsNonEntryPoint() public {
        PackedUserOperation memory op = _withdrawal(0.1 ether, RECIPIENT, 0);
        vm.expectRevert("Sender not EntryPoint");
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.05 ether);
    }
}

/// A note pays for its own gas through the real EntryPoint: the account has no ETH, the EntryPoint takes the gas
/// from the paymaster's deposit, the fee the pool pays the paymaster replaces it, and the operation's own call spends
/// the withdrawn remainder.
contract TacitPaymasterEntryPointTest is Test {
    uint256 internal constant NOTE = 1 ether;
    uint128 internal constant GAS_PRICE = 10 gwei;

    EntryPoint internal entryPoint;
    TacitPaymaster internal paymaster;
    MockTacitPool internal pool;
    OpenAccount internal account;
    address payable internal bundler = payable(address(0xB0B));
    address internal constant SHOP = address(0x5409);

    function setUp() public {
        entryPoint = new EntryPoint();
        paymaster = new TacitPaymaster(
            IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), address(0), 300, address(this)
        );
        pool = new MockTacitPool();
        vm.deal(address(pool), 10 ether);
        paymaster.setPool(ITacitPool(address(pool)), true);
        // The EntryPoint checks the deposit against the operation's maximum cost before validation runs, so the fee
        // collected during validation cannot count towards it: the operator keeps a float and refills it from fees.
        paymaster.deposit{value: 1 ether}();
        account = new OpenAccount();
        vm.txGasPrice(GAS_PRICE);
        vm.fee(GAS_PRICE);
    }

    function _op(uint256 fee, bytes memory callData, uint256 nullifier)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        TacitPaymaster.PaymasterData memory d;
        d.pool = ITacitPool(address(pool));
        d.publicInputs[7] = nullifier;
        d.recipient = payable(address(account));
        // forge-lint: disable-next-line(unsafe-typecast)
        d.extAmount = -int256(NOTE - fee);
        d.fee = fee;

        op.sender = address(account);
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(100_000), uint128(callData.length == 0 ? 0 : 200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(GAS_PRICE), uint128(GAS_PRICE)));
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(500_000), uint128(80_000), abi.encode(d));
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, bundler);
    }

    function test_noteWithNoCallsPaysForItself() public {
        assertEq(address(account).balance, 0);
        uint256 depositBefore = entryPoint.balanceOf(address(paymaster));
        _handle(_op(0.01 ether, "", 1));

        // The bundler was paid the gas, out of the paymaster's deposit.
        uint256 gasCost = bundler.balance;
        assertGt(gasCost, 0);
        assertEq(depositBefore - entryPoint.balanceOf(address(paymaster)), gasCost);
        // The note is fully accounted for: the account and the paymaster hold all of it.
        assertEq(address(account).balance + address(paymaster).balance, NOTE);
        // The paymaster kept at least the gas, so its float is made whole, and the unused part of the fee went back
        // to the account.
        assertGe(address(paymaster).balance, gasCost);
        assertLt(address(paymaster).balance, 0.01 ether);
        assertGt(address(account).balance, NOTE - 0.01 ether);
    }

    function test_operationSpendsTheWithdrawnRemainder() public {
        bytes memory pay = abi.encodeCall(OpenAccount.execute, (SHOP, 0.5 ether, ""));
        _handle(_op(0.01 ether, pay, 2));

        assertEq(SHOP.balance, 0.5 ether);
        assertGt(address(account).balance, 0.48 ether);
        assertEq(address(account).balance + address(paymaster).balance + SHOP.balance, NOTE);
    }

    function test_feeTooSmallForTheGasIsRejected() public {
        PackedUserOperation memory op = _op(1 wei, "", 3);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        vm.expectPartialRevert(IEntryPoint.FailedOpWithRevert.selector); // AA33, inner: InsufficientFee
        entryPoint.handleOps(ops, bundler);
        assertFalse(pool.nullified(3), "a rejected operation leaves the note unspent");
        assertEq(address(account).balance, 0);
    }

    function test_spentNoteIsRejectedBeforeAnyGasIsOwed() public {
        _handle(_op(0.01 ether, "", 4));
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _op(0.01 ether, "", 4);
        ops[0].nonce = 1;
        vm.prank(bundler, bundler);
        vm.expectPartialRevert(IEntryPoint.FailedOpWithRevert.selector); // AA33, inner: AlreadyNullified
        entryPoint.handleOps(ops, bundler);
    }
}
