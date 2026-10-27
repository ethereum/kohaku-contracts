// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {MockPaymaster, GasBurnerAccount} from "./mocks/Mocks.sol";

/// Runs user operations through a real EntryPoint and checks that the
/// paymaster never ends up worse off after refunding the user.
contract RefundAccountingTest is Test {
    uint256 internal constant GAS_PRICE = 1 gwei;
    uint256 internal constant DEPOSIT = 10 ether;
    uint256 internal constant VERIFICATION_GAS_LIMIT = 100_000;
    uint256 internal constant PM_VERIFICATION_GAS_LIMIT = 200_000;
    uint256 internal constant PRE_VERIFICATION_GAS = 50_000;

    address payable internal constant BUNDLER = payable(address(0xB0B));
    address internal constant REFUND_RECIPIENT = address(0xECE1);

    EntryPoint internal entryPoint;
    MockPaymaster internal paymaster;
    GasBurnerAccount internal account;

    function setUp() public {
        entryPoint = new EntryPoint();
        paymaster = new MockPaymaster(IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), address(0), 0);
        account = new GasBurnerAccount();

        paymaster.deposit{value: DEPOSIT}();
        vm.fee(0);
    }

    /// The paymaster's deposit drop plus the refund it sends must never
    /// exceed the fee it collected.
    function testFuzz_paymasterNeverLoses(uint256 burn, uint256 callGasLimit, uint256 postOpGasLimit) public {
        callGasLimit = bound(callGasLimit, 50_000, 2_000_000);
        postOpGasLimit = bound(postOpGasLimit, 50_000, 500_000);
        burn = bound(burn, 0, callGasLimit / 2);

        PackedUserOperation memory op = _buildUserOp(burn, callGasLimit, postOpGasLimit);
        uint256 fee = _maxCost(callGasLimit, postOpGasLimit);
        paymaster.setFee(address(0), fee, REFUND_RECIPIENT);
        // The fee is collected during validation in the real protocols;
        // pre-fund the paymaster to simulate that.
        vm.deal(address(paymaster), fee);

        _handleOp(op);

        uint256 wealthAfter = entryPoint.balanceOf(address(paymaster)) + address(paymaster).balance;
        assertGe(wealthAfter, DEPOSIT, "paymaster lost funds");
        assertGt(REFUND_RECIPIENT.balance, 0, "no refund paid");
    }

    // ----- Helpers -----

    function _buildUserOp(uint256 burn, uint256 callGasLimit, uint256 postOpGasLimit)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(account);
        op.callData = abi.encodeCall(GasBurnerAccount.burn, (burn));
        op.accountGasLimits = bytes32((VERIFICATION_GAS_LIMIT << 128) | callGasLimit);
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = bytes32((GAS_PRICE << 128) | GAS_PRICE);
        op.paymasterAndData =
        // forge-lint: disable-next-line(unsafe-typecast)
        abi.encodePacked(address(paymaster), uint128(PM_VERIFICATION_GAS_LIMIT), uint128(postOpGasLimit));
    }

    function _maxCost(uint256 callGasLimit, uint256 postOpGasLimit) internal pure returns (uint256) {
        return (VERIFICATION_GAS_LIMIT
                + callGasLimit
                + PM_VERIFICATION_GAS_LIMIT
                + postOpGasLimit
                + PRE_VERIFICATION_GAS) * GAS_PRICE;
    }

    function _handleOp(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(ops, BUNDLER);
    }
}
