// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import {ITacitPool} from "../../contracts/tacit/interfaces/ITacitPool.sol";

/// A Tacit ETH pool's `transact` as far as the paymaster sees it: nullifiers are single use, a withdrawal pays its
/// recipient, and the fee is paid to the relayer in the same call. Proofs are not checked.
contract MockTacitPool is ITacitPool {
    error AlreadyNullified();

    mapping(uint256 => bool) public nullified;
    address public lastRelayer;
    address public lastRecipient;
    uint256 public lastFee;
    int256 public lastExtAmount;
    uint256 public calls;

    receive() external payable {}

    function ASSET() external view virtual returns (address) {
        return address(0);
    }

    function transact(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[11] calldata publicInputs,
        address recipient,
        int256 extAmount,
        address relayer,
        uint256 fee,
        bytes calldata,
        bytes calldata
    ) external payable virtual {
        for (uint256 i = 7; i <= 8; ++i) {
            if (publicInputs[i] == 0) continue;
            if (nullified[publicInputs[i]]) revert AlreadyNullified();
            nullified[publicInputs[i]] = true;
        }
        lastRelayer = relayer;
        lastRecipient = recipient;
        lastFee = fee;
        lastExtAmount = extAmount;
        ++calls;
        if (extAmount < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            (bool ok,) = recipient.call{value: uint256(-extAmount)}("");
            require(ok);
        }
        if (fee != 0) {
            (bool ok,) = relayer.call{value: fee}("");
            require(ok);
        }
    }

    function test() public {}
}

/// A pool that holds an ERC20, which the paymaster does not accept.
contract MockTacitTokenPool is MockTacitPool {
    function ASSET() external pure override returns (address) {
        return address(0xA55E7);
    }
}

/// A pool that reports the fee but never pays it.
contract MockStingyTacitPool is MockTacitPool {
    function transact(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[11] calldata,
        address recipient,
        int256 extAmount,
        address,
        uint256,
        bytes calldata,
        bytes calldata
    ) external payable override {
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool ok,) = recipient.call{value: uint256(-extAmount)}("");
        require(ok);
    }
}

/// An account that accepts every operation and runs whatever the EntryPoint asks of it.
contract OpenAccount is IAccount {
    receive() external payable {}

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    function execute(address to, uint256 value, bytes calldata data) external {
        (bool ok,) = to.call{value: value}(data);
        require(ok, "call failed");
    }

    function test() public {}
}
