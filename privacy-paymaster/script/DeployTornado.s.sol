// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Deployments} from "./lib/Deployments.sol";
import {Chains} from "./lib/Chains.sol";

import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {TornadoPaymaster} from "../contracts/tornadocash/TornadoPaymaster.sol";
import {
    ITornadoInstance
} from "../contracts/tornadocash/interfaces/ITornadoInstance.sol";

/// Deploys the `TornadoPaymaster` and allowlists every ETH instance listed
/// under `[protocols.tornado.<name>]` in the chain config.
contract DeployTornado is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        TornadoPaymaster paymaster = deploy(privateKey);
        console.log("Deployed TornadoPaymaster at:", address(paymaster));
        Deployments.writeAddress("tornado", "paymaster", address(paymaster));

        string memory toml = vm.readFile(Chains.path());
        string[] memory instances = vm.parseTomlKeys(
            toml,
            ".protocols.tornado"
        );
        for (uint256 i = 0; i < instances.length; i++) {
            ITornadoInstance instance = ITornadoInstance(
                Chains.readAddress(
                    string.concat("protocols.tornado.", instances[i]),
                    "instance"
                )
            );
            vm.broadcast(privateKey);
            paymaster.setInstance(instance, true);
        }
    }

    function deploy(uint256 privateKey) public returns (TornadoPaymaster) {
        IEntryPoint entryPoint = IEntryPoint(
            Chains.readAddress("protocols.erc4337", "entry_point")
        );

        vm.broadcast(privateKey);
        return new TornadoPaymaster(entryPoint);
    }
}
