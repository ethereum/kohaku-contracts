// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// The part of a Tacit EVM pool this paymaster uses.
interface ITacitPool {
    /// Deposit, private transfer and withdraw in one relation. `extAmount < 0` pays `-extAmount` to `recipient`, and
    /// a non-zero `fee` is paid to `relayer` from the pool in the same call. The proof binds `recipient`, `extAmount`,
    /// `relayer`, `fee` and both memos.
    function transact(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[11] calldata publicInputs,
        address recipient,
        int256 extAmount,
        address relayer,
        uint256 fee,
        bytes calldata memo0,
        bytes calldata memo1
    ) external payable;

    /// The pooled asset; address(0) is native ETH.
    function ASSET() external view returns (address);
}
