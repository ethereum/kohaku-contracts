// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {ITacitPool} from "../contracts/tacit/interfaces/ITacitPool.sol";
import {TacitPaymaster} from "../contracts/tacit/TacitPaymaster.sol";
import {OpenAccount} from "./mocks/TacitMocks.sol";

contract AlwaysTrueVerifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[11] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

interface IRealPool {
    function root() external view returns (bytes32);
    function ASSET() external view returns (address);
    function ASSET_FIELD() external view returns (uint256);
    function nullified(bytes32) external view returns (bool);
}

contract TacitPaymasterRealPoolTest is Test {
    string internal constant POOL_CODE = "test/fixtures/tacit/TacitEvmPool.creation.hex";
    uint256 internal constant P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant NOTE = 1 ether;
    uint256 internal constant FEE = 0.01 ether;
    uint128 internal constant GAS_PRICE = 10 gwei;

    EntryPoint internal entryPoint;
    TacitPaymaster internal paymaster;
    IRealPool internal pool;
    OpenAccount internal account;
    address payable internal bundler = payable(address(0xB0B));

    function setUp() public {
        entryPoint = new EntryPoint();
        paymaster = new TacitPaymaster(IEntryPoint(address(entryPoint)), IUniswapV3Factory(address(0)), address(0), 300);
        address verifier = address(new AlwaysTrueVerifier());
        pool = IRealPool(_deployPool(verifier));
        vm.deal(address(pool), 5 ether);
        paymaster.setPool(ITacitPool(address(pool)), true);
        paymaster.deposit{value: 1 ether}();
        account = new OpenAccount();
        vm.txGasPrice(GAS_PRICE);
        vm.fee(GAS_PRICE);
    }

    /// The live pool's creation code (TacitEvmPool at 0x000000c2A20657CE25f2Ba99737933D031AFBEE9, solc 0.8.36) with an
    /// ETH asset and the verifier given. The verifier here accepts every proof, so these tests cover what the pool
    /// enforces around the proof: the bindings, the payouts and the nullifiers.
    function _deployPool(address verifier) internal returns (address deployed) {
        bytes memory code = bytes.concat(vm.parseBytes(vm.readFile(POOL_CODE)), abi.encode(verifier, address(0)));
        assembly {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0), "pool deployment failed");
    }

    function _op(uint256 nf, uint256 nonce) internal view returns (PackedUserOperation memory op) {
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 extAmount = -int256(NOTE - FEE);
        uint256 extHash = uint256(
            keccak256(
                abi.encode(
                    block.chainid,
                    address(pool),
                    address(account),
                    extAmount,
                    address(paymaster),
                    FEE,
                    keccak256(""),
                    keccak256("")
                )
            )
        ) % P;
        TacitPaymaster.PaymasterData memory d;
        d.pool = ITacitPool(address(pool));
        d.publicInputs[0] = uint256(pool.root());
        d.publicInputs[1] = uint256(pool.root());
        d.publicInputs[4] = P - NOTE; // (extAmount - fee) mod p
        d.publicInputs[5] = extHash;
        d.publicInputs[6] = pool.ASSET_FIELD();
        d.publicInputs[7] = nf;
        d.recipient = payable(address(account));
        d.extAmount = extAmount;
        d.fee = FEE;

        op.sender = address(account);
        op.nonce = nonce;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(100_000), uint128(0)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(GAS_PRICE), uint128(GAS_PRICE)));
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(600_000), uint128(80_000), abi.encode(d));
    }

    function test_realPoolPaysTheGasOfItsOwnWithdrawal() public {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _op(111, 0);
        uint256 poolBefore = address(pool).balance;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, bundler);

        assertTrue(pool.nullified(bytes32(uint256(111))));
        assertEq(poolBefore - address(pool).balance, NOTE);
        assertEq(address(account).balance + address(paymaster).balance, NOTE);
        assertGe(address(paymaster).balance, bundler.balance);

        // The same note cannot pay twice.
        ops[0] = _op(111, 1);
        vm.prank(bundler, bundler);
        vm.expectPartialRevert(IEntryPoint.FailedOpWithRevert.selector);
        entryPoint.handleOps(ops, bundler);
    }

    function test_realPoolRefusesAnotherRelayerOrFee() public {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _op(222, 0);
        // Raise the fee after the "proof" bound the old one: the pool recomputes extDataHash and refuses.
        TacitPaymaster.PaymasterData memory d =
            abi.decode(_data(ops[0].paymasterAndData), (TacitPaymaster.PaymasterData));
        d.fee = FEE + 1;
        ops[0].paymasterAndData = abi.encodePacked(address(paymaster), uint128(600_000), uint128(80_000), abi.encode(d));
        vm.prank(bundler, bundler);
        vm.expectPartialRevert(IEntryPoint.FailedOpWithRevert.selector);
        entryPoint.handleOps(ops, bundler);
        assertFalse(pool.nullified(bytes32(uint256(222))));
    }

    function _data(bytes memory paymasterAndData) internal pure returns (bytes memory out) {
        out = new bytes(paymasterAndData.length - 52);
        for (uint256 i; i < out.length; ++i) {
            out[i] = paymasterAndData[i + 52];
        }
    }
}
