// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Deployments} from "./lib/Deployments.sol";

import {BasePrivacyPaymaster} from "../contracts/BasePrivacyPaymaster.sol";

contract WithdrawPaymaster is Script {
    function run() external {
        // Deployment section of the paymaster to use: tornado, privacypools or railgun.
        address paymasterAddr = Deployments.readAddress(
            vm.envString("PAYMASTER"),
            "paymaster"
        );
        uint256 withdrawAmount = vm.envOr("WITHDRAW_AMOUNT", uint256(0));
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        withdraw(paymasterAddr, withdrawAmount, privateKey);
    }

    function withdraw(
        address paymasterAddr,
        uint256 withdrawAmount,
        uint256 privateKey
    ) public {
        BasePrivacyPaymaster paymaster = BasePrivacyPaymaster(payable(paymasterAddr));

        vm.broadcast(privateKey);
        address payable to = payable(vm.addr(privateKey));
        paymaster.withdrawTo(to, withdrawAmount);
    }
}
