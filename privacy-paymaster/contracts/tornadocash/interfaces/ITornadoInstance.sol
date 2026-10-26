// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface ITornadoInstance {
    function deposit(bytes32 _commitment) external payable;
    function denomination() external view returns (uint256);
    function withdraw(
        bytes calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        address payable _recipient,
        address payable _relayer,
        uint256 _fee,
        uint256 _refund
    ) external;
}
