// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Chains} from "./lib/Chains.sol";
import {PaymasterSetup} from "./lib/PaymasterSetup.sol";

import {
    IEntryPoint
} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {
    IUniswapV3Factory
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {TornadoPaymaster} from "../contracts/tornadocash/TornadoPaymaster.sol";
import {
    ITornadoInstance
} from "../contracts/tornadocash/interfaces/ITornadoInstance.sol";

/// Deploys the `TornadoPaymaster` and allowlists every instance listed under
/// `[protocols.tornado.<name>]` in the chain config.
contract DeployTornado is Script {
    function run() external returns (TornadoPaymaster paymaster) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        paymaster = deploy(privateKey);
        console.log("Deployed TornadoPaymaster at:", address(paymaster));

        string memory toml = vm.readFile(Chains.path());
        string[] memory instances = vm.parseTomlKeys(
            toml,
            ".protocols.tornado"
        );
        for (uint256 i = 0; i < instances.length; i++) {
            allowInstance(
                paymaster,
                string.concat("protocols.tornado.", instances[i]),
                privateKey
            );
        }
    }

    function deploy(uint256 privateKey) public returns (TornadoPaymaster) {
        (
            IEntryPoint entryPoint,
            IUniswapV3Factory factory,
            address weth,
            uint32 twapPeriod
        ) = PaymasterSetup.baseArgs();

        vm.broadcast(privateKey);
        return new TornadoPaymaster(entryPoint, factory, weth, twapPeriod);
    }

    function allowInstance(
        TornadoPaymaster paymaster,
        string memory tomlKey,
        uint256 privateKey
    ) public {
        ITornadoInstance instance = ITornadoInstance(
            Chains.readAddress(tomlKey, "instance")
        );

        vm.broadcast(privateKey);
        paymaster.setInstance(instance, true);

        (, address token) = paymaster.instances(instance);
        if (token != address(0)) {
            PaymasterSetup.allowFeeToken(paymaster, token, tomlKey, privateKey);
        }
    }
}
