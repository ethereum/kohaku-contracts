// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ShieldRequest, Transaction, CommitmentPreimage} from "../Globals.sol";

interface IRailgunSmartWallet {
    function hashLeftRight(
        bytes32 _left,
        bytes32 _right
    ) external pure returns (bytes32);
    function hashCommitment(
        CommitmentPreimage memory _commitmentPreimage
    ) external pure returns (bytes32);

    function shield(ShieldRequest[] calldata _shieldRequests) external;
    function transact(Transaction[] calldata _transactions) external;

}
