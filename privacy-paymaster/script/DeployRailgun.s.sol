// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Deployments} from "./lib/Deployments.sol";
import {Chains} from "./lib/Chains.sol";

import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {RailgunPaymaster} from "../contracts/railgun/RailgunPaymaster.sol";
import {
    IRailgunSmartWallet
} from "../contracts/railgun/interfaces/IRailgunSmartWallet.sol";

contract DeployRailgun is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        RailgunPaymaster paymaster = deploy(privateKey);
        console.log("Deployed RailgunPaymaster at:", address(paymaster));
        Deployments.writeAddress("railgun", "paymaster", address(paymaster));
    }

    function deploy(uint256 privateKey) public returns (RailgunPaymaster) {
        IEntryPoint entryPoint = IEntryPoint(
            Chains.readAddress("protocols.erc4337", "entry_point")
        );
        IRailgunSmartWallet railgunSmartWallet = IRailgunSmartWallet(
            Chains.readAddress("protocols.railgun", "smart_wallet")
        );
        address weth = Chains.readAddress("tokens", "weth");
        bytes32 masterPublicKey = Chains.readBytes32(
            "protocols.railgun",
            "master_public_key"
        );

        vm.broadcast(privateKey);
        return
            new RailgunPaymaster(
                entryPoint,
                railgunSmartWallet,
                weth,
                masterPublicKey
            );
    }
}
