// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

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
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(500_000), uint128(50_000), abi.encode(data));
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

contract TornadoPaymasterIntegrationTest is Test {
    address internal constant SENDER = address(0x5EDE2);
    uint256 internal constant DENOMINATION = 0.1 ether;
    // The withdraw circuit has 20 levels, so the proof's root only matches a depth-20 tree.
    uint32 internal constant MERKLE_TREE_HEIGHT = 20;
    // ETH fees never read the Uniswap oracle, so the factory, WETH and TWAP period are placeholders.
    uint32 internal constant TWAP_PERIOD = 300;
    uint128 internal constant PAYMASTER_VERIFICATION_GAS_LIMIT = 500_000;
    uint128 internal constant PAYMASTER_POST_OP_GAS_LIMIT = 50_000;

    ITornadoInstance internal tornado;
    TornadoPaymaster internal paymaster;
    EntryPoint internal entryPoint;

    function setUp() public {
        address hasher = _deploy(TornadoFixtures.loadCreationCode("hasher"));
        address verifier = _deploy(TornadoFixtures.loadCreationCode("verifier"));
        tornado = ITornadoInstance(
            _deploy(
                bytes.concat(
                    TornadoFixtures.loadCreationCode("eth_tornado"),
                    abi.encode(verifier, hasher, DENOMINATION, MERKLE_TREE_HEIGHT)
                )
            )
        );
        entryPoint = new EntryPoint();

        // Deploy the paymaster at the fixture relayer address so the proof's
        // committed relayer matches the paymaster.
        address paymasterAddr = TornadoFixtures.loadRelayer();
        deployCodeTo(
            "TornadoPaymaster.sol:TornadoPaymaster",
            abi.encode(IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), makeAddr("weth"), TWAP_PERIOD),
            paymasterAddr
        );
        paymaster = TornadoPaymaster(payable(paymasterAddr));
        paymaster.setInstance(tornado, true);

        tornado.deposit{value: DENOMINATION}(TornadoFixtures.loadCommitment());
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
        op.paymasterAndData = abi.encodePacked(
            address(paymaster), PAYMASTER_VERIFICATION_GAS_LIMIT, PAYMASTER_POST_OP_GAS_LIMIT, abi.encode(data)
        );
    }

    function _deploy(bytes memory code) internal returns (address addr) {
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), "deploy failed");
    }

    // ----- Tests -----

    function test_valid() public {
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(_buildUserOp(), bytes32(0), TornadoFixtures.loadFee());

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(0));
        assertEq(ctx.feePaid, TornadoFixtures.loadFee());
        assertEq(ctx.refundRecipient, TornadoFixtures.loadRecipient());
        assertEq(ctx.maxCost, TornadoFixtures.loadFee());
        assertEq(ctx.maxCostInToken, TornadoFixtures.loadFee());
        assertEq(validationData, 0);
        assertEq(address(paymaster).balance, TornadoFixtures.loadFee());
    }
}
