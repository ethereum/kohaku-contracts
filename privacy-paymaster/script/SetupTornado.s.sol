// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Chains} from "./lib/Chains.sol";
import {PaymasterSetup} from "./lib/PaymasterSetup.sol";

import {TornadoPaymaster} from "../contracts/tornadocash/TornadoPaymaster.sol";
import {ITornadoInstance} from "../contracts/tornadocash/interfaces/ITornadoInstance.sol";

/// Allowlists every instance under `[protocols.tornado.<name>]` in the
/// chain config on the `TornadoPaymaster` at `PAYMASTER_ADDRESS`.
contract SetupTornado is Script {
    function run() external {
        TornadoPaymaster paymaster = TornadoPaymaster(payable(vm.envAddress("PAYMASTER_ADDRESS")));
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        string memory toml = vm.readFile(Chains.path());
        string[] memory instances = vm.parseTomlKeys(toml, ".protocols.tornado");
        for (uint256 i = 0; i < instances.length; i++) {
            allowInstance(paymaster, string.concat("protocols.tornado.", instances[i]), privateKey);
        }
    }

    function allowInstance(TornadoPaymaster paymaster, string memory tomlKey, uint256 privateKey) public {
        ITornadoInstance instance = ITornadoInstance(Chains.readAddress(tomlKey, "instance"));

        (bool allowed,) = paymaster.instances(instance);
        if (!allowed) {
            vm.broadcast(privateKey);
            paymaster.setInstance(instance, true);
        }

        (, address token) = paymaster.instances(instance);
        if (token != address(0)) {
            PaymasterSetup.allowFeeToken(paymaster, token, tomlKey, privateKey);
        }
    }
}
