// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Chains} from "../script/lib/Chains.sol";

import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {
    PackedUserOperation
} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IRailgunSmartWallet
} from "../contracts/railgun/interfaces/IRailgunSmartWallet.sol";
import {RailgunPaymaster} from "../contracts/railgun/RailgunPaymaster.sol";
import {
    Transaction,
    ShieldRequest
} from "../contracts/railgun/Globals.sol";
import {RailgunFixtures} from "./fixtures/RailgunFixtures.sol";

contract RailgunPaymasterForkTest is Test {
    IRailgunSmartWallet internal railgun;
    RailgunPaymaster internal paymaster;
    address internal entryPointAddr;
    bytes32 internal masterPublicKey;

    function setUp() public {
        // Skip when there's no Sepolia RPC, e.g. on PRs from forks,
        // which don't get secrets.
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(vm.rpcUrl("sepolia"), RailgunFixtures.FORK_BLOCK);

        entryPointAddr = Chains.readAddress("protocols.erc4337", "entry_point");
        address weth = Chains.readAddress("tokens", "weth");
        address smartWalletAddr = Chains.readAddress(
            "protocols.railgun",
            "smart_wallet"
        );
        masterPublicKey = Chains.readBytes32(
            "protocols.railgun",
            "master_public_key"
        );

        railgun = IRailgunSmartWallet(smartWalletAddr);

        address depositor = address(0xDEADBEEF);
        vm.deal(depositor, 1 ether);
        vm.prank(depositor);
        (bool ok, ) = weth.call{value: 1 ether}(
            abi.encodeWithSignature("deposit()")
        );
        require(ok, "WETH deposit failed");
        vm.prank(depositor);
        IERC20(weth).approve(smartWalletAddr, 1 ether);

        ShieldRequest[] memory requests = new ShieldRequest[](1);
        requests[0] = RailgunFixtures.loadShield();
        vm.prank(depositor);
        railgun.shield(requests);

        paymaster = new RailgunPaymaster(
            IEntryPoint(entryPointAddr),
            railgun,
            weth,
            masterPublicKey
        );
    }

    // ----- Helpers -----

    function _buildUserOp(
        Transaction memory t
    ) internal view returns (PackedUserOperation memory op) {
        Transaction[] memory transactions = new Transaction[](1);
        transactions[0] = t;

        bytes memory paymasterData = abi.encode(
            RailgunPaymaster.PaymasterData({
                random: RailgunFixtures.loadRandom(),
                value: RailgunFixtures.loadValue(),
                transactions: transactions
            })
        );
        op.sender = address(0); // matches fixture's adaptParams = bytes32(0)
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(500_000),
            uint128(50_000),
            paymasterData
        );
    }

    // ----- Tests -----

    function test_valid() public {
        PackedUserOperation memory op = _buildUserOp(
            RailgunFixtures.loadTransaction()
        );
        vm.prank(entryPointAddr);
        (bytes memory context, uint256 validationData) = paymaster
            .validatePaymasterUserOp(
                op,
                bytes32(0),
                uint256(RailgunFixtures.loadValue())
            );
        assertEq(context, "");
        assertEq(validationData, 0);
    }

    function test_adaptParamsNotSender() public {
        PackedUserOperation memory op = _buildUserOp(
            RailgunFixtures.loadTransaction()
        );
        op.sender = address(0xDEAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                RailgunPaymaster.AdaptParamsAreNotSender.selector,
                bytes32(0),
                address(0xDEAD)
            )
        );
        vm.prank(entryPointAddr);
        paymaster.validatePaymasterUserOp(
            op,
            bytes32(0),
            uint256(RailgunFixtures.loadValue())
        );
    }

    function test_missingFee() public {
        Transaction memory t = RailgunFixtures.loadTransaction();
        for (uint256 i = 0; i < t.commitments.length; i++) {
            t.commitments[i] = bytes32(0);
        }
        PackedUserOperation memory op = _buildUserOp(t);
        vm.expectRevert(
            abi.encodeWithSelector(
                RailgunPaymaster.MissingFee.selector,
                masterPublicKey,
                RailgunFixtures.loadRandom(),
                RailgunFixtures.loadValue()
            )
        );
        vm.prank(entryPointAddr);
        paymaster.validatePaymasterUserOp(
            op,
            bytes32(0),
            uint256(RailgunFixtures.loadValue())
        );
    }
}
