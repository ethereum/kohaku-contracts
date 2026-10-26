// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Deployments} from "./lib/Deployments.sol";
import {Chains} from "./lib/Chains.sol";
import {PaymasterSetup} from "./lib/PaymasterSetup.sol";

import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {
    IUniswapV3Factory
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {RailgunPaymaster} from "../contracts/railgun/RailgunPaymaster.sol";
import {
    IRailgunSmartWallet
} from "../contracts/railgun/interfaces/IRailgunSmartWallet.sol";

contract DeployRailgun is Script {
    function run() external {
        IRailgunSmartWallet railgunSmartWallet = IRailgunSmartWallet(
            Chains.readAddress("protocols.railgun", "smart_wallet")
        );
        bytes32 masterPublicKey = Chains.readBytes32(
            "protocols.railgun",
            "master_public_key"
        );
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        RailgunPaymaster paymaster = deploy(
            railgunSmartWallet,
            masterPublicKey,
            privateKey
        );
        console.log("Deployed RailgunPaymaster at:", address(paymaster));
        Deployments.writeAddress("railgun", "paymaster", address(paymaster));
    }

    function deploy(
        IRailgunSmartWallet railgunSmartWallet,
        bytes32 masterPublicKey,
        uint256 privateKey
    ) public returns (RailgunPaymaster) {
        (
            IEntryPoint entryPoint,
            IUniswapV3Factory factory,
            address weth,
            uint32 twapPeriod
        ) = PaymasterSetup.baseArgs();

        vm.broadcast(privateKey);
        return
            new RailgunPaymaster(
                entryPoint,
                factory,
                weth,
                twapPeriod,
                railgunSmartWallet,
                masterPublicKey
            );
    }
}
