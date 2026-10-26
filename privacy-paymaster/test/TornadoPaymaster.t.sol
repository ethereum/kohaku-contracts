// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Chains} from "../script/lib/Chains.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

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
    MockERC20 internal token;
    MockEthTornado internal ethInstance;
    MockERC20Tornado internal erc20Instance;

    function setUp() public {
        entryPoint = new EntryPoint();
        // Use the ERC20 as WETH so it's priced 1:1 without an oracle.
        token = new MockERC20();
        paymaster =
            new TornadoPaymaster(IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), address(token), 300);

        ethInstance = new MockEthTornado();
        vm.deal(address(ethInstance), 1 ether);
        erc20Instance = new MockERC20Tornado(IERC20(address(token)));
        token.mint(address(erc20Instance), 100 ether);

        paymaster.setInstance(ITornadoInstance(address(ethInstance)), true);
        paymaster.setInstance(ITornadoInstance(address(erc20Instance)), true);
    }

    // ----- Helpers -----

    function _buildUserOp(address instance, address sender, uint256 fee, uint256 callGasLimit)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        TornadoPaymaster.PaymasterData memory data = TornadoPaymaster.PaymasterData({
            instance: ITornadoInstance(instance),
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

    function test_setInstance_eth() public {
        ITornadoInstance other = ITornadoInstance(address(new MockEthTornado()));

        vm.expectEmit(true, false, false, true);
        emit TornadoPaymaster.InstanceSet(address(other), true);
        paymaster.setInstance(other, true);

        (bool allowed, address instanceToken) = paymaster.instances(other);
        assertTrue(allowed);
        assertEq(instanceToken, address(0));
    }

    function test_setInstance_erc20() public {
        ITornadoInstance other = ITornadoInstance(address(new MockERC20Tornado(IERC20(address(token)))));
        paymaster.setInstance(other, true);

        (bool allowed, address instanceToken) = paymaster.instances(other);
        assertTrue(allowed);
        assertEq(instanceToken, address(token));
    }

    function test_setInstance_disallow() public {
        paymaster.setInstance(ITornadoInstance(address(ethInstance)), false);
        (bool allowed,) = paymaster.instances(ITornadoInstance(address(ethInstance)));
        assertFalse(allowed);
    }

    function test_setInstance_rejectsNonOwner() public {
        vm.prank(SENDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, SENDER));
        paymaster.setInstance(ITornadoInstance(address(ethInstance)), false);
    }

    // ----- Validation -----

    function test_valid_eth() public {
        bytes memory context = _validate(_buildUserOp(address(ethInstance), SENDER, 0.1 ether, 0), 0.05 ether);

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(0));
        assertEq(ctx.feePaid, 0.1 ether);
        assertEq(ctx.refundRecipient, RECIPIENT);
        assertEq(ethInstance.lastRelayer(), address(paymaster));
        assertEq(address(paymaster).balance, 0.1 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }

    function test_valid_erc20() public {
        bytes memory context = _validate(_buildUserOp(address(erc20Instance), SENDER, 5 ether, 0), 1 ether);

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(token));
        assertEq(token.balanceOf(address(paymaster)), 5 ether);
        assertEq(token.balanceOf(RECIPIENT), 95 ether);
    }

    function test_valid_recipientIsSenderAllowsCallGasLimit() public {
        _validate(_buildUserOp(address(ethInstance), RECIPIENT, 0.1 ether, 1_000_000), 0.05 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }

    function test_instanceNotAllowed() public {
        address other = address(new MockEthTornado());
        PackedUserOperation memory op = _buildUserOp(other, SENDER, 0.1 ether, 0);

        vm.expectRevert(abi.encodeWithSelector(TornadoPaymaster.InstanceNotAllowed.selector, other));
        _validate(op, 0.05 ether);
    }

    function test_callGasLimitNonZero() public {
        PackedUserOperation memory op = _buildUserOp(address(ethInstance), SENDER, 0.1 ether, 1_000_000);

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.CallGasLimitNonZero.selector, 1_000_000));
        _validate(op, 0.05 ether);
    }

    function test_insufficientFee() public {
        PackedUserOperation memory op = _buildUserOp(address(ethInstance), SENDER, 0.01 ether, 0);

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
        address factory = Chains.readAddress("protocols.uniswap_v3", "factory");
        address weth = Chains.readAddress("tokens", "weth");
        uint32 twapPeriod = uint32(Chains.readUint("protocols.uniswap_v3", "twap_period"));
        tornado = ITornadoInstance(Chains.readAddress("protocols.tornado.eth_1", "instance"));

        // Deploy the paymaster at the fixture relayer address so the proof's
        // committed relayer matches the paymaster.
        address paymasterAddr = TornadoFixtures.loadRelayer();
        deployCodeTo(
            "TornadoPaymaster.sol:TornadoPaymaster",
            abi.encode(IEntryPoint(entryPointAddr), IUniswapV3Factory(factory), weth, twapPeriod),
            paymasterAddr
        );
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
        assertEq(ctx.feeToken, address(0));
        assertEq(ctx.feePaid, TornadoFixtures.loadFee());
        assertEq(ctx.refundRecipient, TornadoFixtures.loadRecipient());
        assertEq(ctx.maxCost, TornadoFixtures.loadFee());
        assertEq(ctx.maxCostInToken, TornadoFixtures.loadFee());
        assertEq(validationData, 0);
    }
}
