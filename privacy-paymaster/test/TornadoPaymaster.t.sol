// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Chains} from "../script/lib/Chains.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {BasePrivacyPaymaster} from "../contracts/BasePrivacyPaymaster.sol";
import {ITornadoInstance} from "../contracts/tornadocash/interfaces/ITornadoInstance.sol";
import {TornadoPaymaster} from "../contracts/tornadocash/TornadoPaymaster.sol";
import {MockERC20, MockEthTornado, MockERC20Tornado} from "./mocks/Mocks.sol";
import {TornadoFixtures} from "./fixtures/TornadoFixtures.sol";

function buildTornadoUserOp(
    address paymaster,
    TornadoPaymaster.PaymasterData memory data,
    address sender,
    uint256 callGasLimit
) pure returns (PackedUserOperation memory op) {
    op.sender = sender;
    op.accountGasLimits = bytes32(callGasLimit);
    op.paymasterAndData = abi.encodePacked(paymaster, uint128(500_000), uint128(50_000), abi.encode(data));
}

contract TornadoPaymasterTest is Test {
    address internal constant SENDER = address(0x5EDE2);
    address payable internal constant RECIPIENT = payable(address(0x5A71CE2));

    EntryPoint internal entryPoint;
    TornadoPaymaster internal paymaster;
    MockEthTornado internal ethInstance;
    MockERC20Tornado internal erc20Instance;
    MockERC20 internal token;

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

    function _data(address instance, uint256 fee) internal pure returns (TornadoPaymaster.PaymasterData memory) {
        return TornadoPaymaster.PaymasterData({
            instance: ITornadoInstance(instance),
            proof: "",
            root: bytes32(0),
            nullifierHash: bytes32(0),
            recipient: RECIPIENT,
            fee: fee
        });
    }

    function _validate(PackedUserOperation memory op, uint256 maxCost) internal returns (bytes memory ctx) {
        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
    }

    // ----- Admin -----

    function test_setInstance_detectsToken() public view {
        (bool allowed, address ethToken) = paymaster.instances(ITornadoInstance(address(ethInstance)));
        assertTrue(allowed);
        assertEq(ethToken, address(0));

        (, address erc20Token) = paymaster.instances(ITornadoInstance(address(erc20Instance)));
        assertEq(erc20Token, address(token));
    }

    function test_setInstance_disallow() public {
        paymaster.setInstance(ITornadoInstance(address(ethInstance)), false);
        (bool allowed,) = paymaster.instances(ITornadoInstance(address(ethInstance)));
        assertFalse(allowed);
    }

    // ----- Validation -----

    function test_valid_eth() public {
        PackedUserOperation memory op = buildTornadoUserOp(address(paymaster), _data(address(ethInstance), 0.1 ether), SENDER, 0);
        bytes memory context = _validate(op, 0.05 ether);

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(0));
        assertEq(ctx.feePaid, 0.1 ether);
        assertEq(ctx.refundRecipient, RECIPIENT);
        assertEq(ethInstance.lastRelayer(), address(paymaster));
        assertEq(address(paymaster).balance, 0.1 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }

    function test_valid_erc20() public {
        PackedUserOperation memory op = buildTornadoUserOp(address(paymaster), _data(address(erc20Instance), 5 ether), SENDER, 0);
        bytes memory context = _validate(op, 1 ether);

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(token));
        assertEq(token.balanceOf(address(paymaster)), 5 ether);
        assertEq(token.balanceOf(RECIPIENT), 95 ether);
    }

    function test_instanceNotAllowed() public {
        MockEthTornado other = new MockEthTornado();
        PackedUserOperation memory op = buildTornadoUserOp(address(paymaster), _data(address(other), 0.1 ether), SENDER, 0);

        vm.expectRevert(abi.encodeWithSelector(TornadoPaymaster.InstanceNotAllowed.selector, address(other)));
        _validate(op, 0.05 ether);
    }

    function test_callGasLimitNonZero() public {
        PackedUserOperation memory op =
            buildTornadoUserOp(address(paymaster), _data(address(ethInstance), 0.1 ether), SENDER, 1_000_000);

        vm.expectRevert(abi.encodeWithSelector(BasePrivacyPaymaster.CallGasLimitNonZero.selector, 1_000_000));
        _validate(op, 0.05 ether);
    }

    function test_recipientIsSenderAllowsCallGasLimit() public {
        PackedUserOperation memory op =
            buildTornadoUserOp(address(paymaster), _data(address(ethInstance), 0.1 ether), RECIPIENT, 1_000_000);
        _validate(op, 0.05 ether);
        assertEq(RECIPIENT.balance, 0.9 ether);
    }
}

contract TornadoPaymasterForkTest is Test {
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

    function _buildUserOp(address sender, uint256 callGasLimit) internal view returns (PackedUserOperation memory) {
        TornadoPaymaster.PaymasterData memory data = TornadoPaymaster.PaymasterData({
            instance: tornado,
            proof: TornadoFixtures.loadProof(),
            root: TornadoFixtures.loadRoot(),
            nullifierHash: TornadoFixtures.loadNullifierHash(),
            recipient: TornadoFixtures.loadRecipient(),
            fee: TornadoFixtures.loadFee()
        });
        return buildTornadoUserOp(address(paymaster), data, sender, callGasLimit);
    }

    function test_valid() public {
        PackedUserOperation memory op = _buildUserOp(address(0x5EDE2), 0);
        vm.prank(entryPointAddr);
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(op, bytes32(0), TornadoFixtures.loadFee());

        BasePrivacyPaymaster.PostOpContext memory ctx = abi.decode(context, (BasePrivacyPaymaster.PostOpContext));
        assertEq(ctx.feeToken, address(0));
        assertEq(ctx.feePaid, TornadoFixtures.loadFee());
        assertEq(ctx.refundRecipient, TornadoFixtures.loadRecipient());
        assertEq(ctx.maxCost, TornadoFixtures.loadFee());
        assertEq(ctx.maxCostInToken, TornadoFixtures.loadFee());
        assertEq(validationData, 0);
    }
}
