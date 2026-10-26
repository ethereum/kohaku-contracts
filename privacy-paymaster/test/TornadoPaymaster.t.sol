// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Chains} from "../script/lib/Chains.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BasePrivacyPaymaster} from "../contracts/BasePrivacyPaymaster.sol";
import {ITornadoInstance} from "../contracts/tornadocash/interfaces/ITornadoInstance.sol";
import {TornadoPaymaster} from "../contracts/tornadocash/TornadoPaymaster.sol";
import {MockERC20, MockEthTornado, MockERC20Tornado} from "./mocks/Mocks.sol";
import {TornadoFixtures} from "./fixtures/TornadoFixtures.sol";

contract TornadoPaymasterTest is Test {
    address internal constant SENDER = address(0x5EDE2);
    address payable internal constant RECIPIENT = payable(address(0x5A71CE2));

    EntryPoint internal entryPoint;
    TornadoPaymaster internal paymaster;
    MockEthTornado internal instance;

    function setUp() public {
        entryPoint = new EntryPoint();
        paymaster = new TornadoPaymaster(IEntryPoint(address(entryPoint)));

        instance = new MockEthTornado();
        vm.deal(address(instance), 1 ether);
        paymaster.setInstance(ITornadoInstance(address(instance)), true);
    }

    // ----- Helpers -----

    function _buildUserOp(address _instance, address sender, uint256 fee, uint256 callGasLimit)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        TornadoPaymaster.PaymasterData memory data = TornadoPaymaster.PaymasterData({
            instance: ITornadoInstance(_instance),
            proof: "",
            root: bytes32(0),
            nullifierHash: bytes32(0),
            recipient: RECIPIENT,
            fee: fee
        });

        op.sender = sender;
        op.accountGasLimits = bytes32(callGasLimit);
        op.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(500_000), uint128(50_000), abi.encode(data));
    }

    function _validate(PackedUserOperation memory op, uint256 maxCost) internal returns (bytes memory ctx) {
        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
    }

    // ----- Admin -----

    function test_setInstance() public {
        ITornadoInstance other = ITornadoInstance(address(new MockEthTornado()));

        vm.expectEmit(true, false, false, true);
        emit TornadoPaymaster.InstanceSet(address(other), true);
        paymaster.setInstance(other, true);

        assertTrue(paymaster.instances(other));
    }

    function test_setInstance_disallow() public {
        paymaster.setInstance(ITornadoInstance(address(instance)), false);
        assertFalse(paymaster.instances(ITornadoInstance(address(instance))));
    }

    function test_setInstance_rejectsErc20Instance() public {
        MockERC20Tornado erc20Instance = new MockERC20Tornado(address(new MockERC20()));

        vm.expectRevert(abi.encodeWithSelector(TornadoPaymaster.NotEthInstance.selector, address(erc20Instance)));
        paymaster.setInstance(ITornadoInstance(address(erc20Instance)), true);
    }

    function test_setInstance_rejectsNonOwner() public {
        vm.prank(SENDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, SENDER));
        paymaster.setInstance(ITornadoInstance(address(instance)), false);
    }

    // ----- Validation -----

    function test_valid() public {
        bytes memory context = _validate(_buildUserOp(address(instance), SENDER, 0.1 ether, 0), 0.05 ether);

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feePaid, 0.1 ether);
        assertEq(ctx.refundRecipient, RECIPIENT);
        assertEq(instance.lastRelayer(), address(paymaster));
        assertEq(address(paymaster).balance, 0.1 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }

    function test_valid_recipientIsSenderAllowsCallGasLimit() public {
        _validate(_buildUserOp(address(instance), RECIPIENT, 0.1 ether, 1_000_000), 0.05 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }

    function test_instanceNotAllowed() public {
        address other = address(new MockEthTornado());
        PackedUserOperation memory op = _buildUserOp(other, SENDER, 0.1 ether, 0);

        vm.expectRevert(abi.encodeWithSelector(TornadoPaymaster.InstanceNotAllowed.selector, other));
        _validate(op, 0.05 ether);
    }

    function test_callGasLimitNonZero() public {
        PackedUserOperation memory op = _buildUserOp(address(instance), SENDER, 0.1 ether, 1_000_000);

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.CallGasLimitNonZero.selector, 1_000_000));
        _validate(op, 0.05 ether);
    }

    function test_insufficientFee() public {
        PackedUserOperation memory op = _buildUserOp(address(instance), SENDER, 0.01 ether, 0);

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.InsufficientFee.selector, 0.1 ether, 0.01 ether));
        _validate(op, 0.1 ether);
    }
}

contract TornadoPaymasterForkTest is Test {
    address internal constant SENDER = address(0x5EDE2);

    ITornadoInstance internal tornado;
    TornadoPaymaster internal paymaster;
    address internal entryPointAddr;

    function setUp() public {
        // Skip when there's no Sepolia RPC, e.g. on PRs from forks,
        // which don't get secrets.
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(vm.rpcUrl("sepolia"), TornadoFixtures.loadForkBlock());

        entryPointAddr = Chains.readAddress("protocols.erc4337", "entry_point");
        tornado = ITornadoInstance(Chains.readAddress("protocols.tornado.eth_1", "instance"));

        // Deploy the paymaster at the fixture relayer address so the proof's
        // committed relayer matches the paymaster.
        address paymasterAddr = TornadoFixtures.loadRelayer();
        deployCodeTo("TornadoPaymaster.sol:TornadoPaymaster", abi.encode(IEntryPoint(entryPointAddr)), paymasterAddr);
        paymaster = TornadoPaymaster(payable(paymasterAddr));
        paymaster.setInstance(tornado, true);

        address depositor = address(0xDEADBEEF);
        vm.deal(depositor, tornado.denomination());
        vm.prank(depositor);
        tornado.deposit{value: tornado.denomination()}(TornadoFixtures.loadCommitment());
    }

    // ----- Helpers -----

    function _buildUserOp() internal view returns (PackedUserOperation memory op) {
        TornadoPaymaster.PaymasterData memory data = TornadoPaymaster.PaymasterData({
            instance: tornado,
            proof: TornadoFixtures.loadProof(),
            root: TornadoFixtures.loadRoot(),
            nullifierHash: TornadoFixtures.loadNullifierHash(),
            recipient: TornadoFixtures.loadRecipient(),
            fee: TornadoFixtures.loadFee()
        });

        op.sender = SENDER;
        op.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(500_000), uint128(50_000), abi.encode(data));
    }

    // ----- Tests -----

    function test_valid() public {
        vm.prank(entryPointAddr);
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(_buildUserOp(), bytes32(0), TornadoFixtures.loadFee());

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feePaid, TornadoFixtures.loadFee());
        assertEq(ctx.refundRecipient, TornadoFixtures.loadRecipient());
        assertEq(validationData, 0);
    }
}
