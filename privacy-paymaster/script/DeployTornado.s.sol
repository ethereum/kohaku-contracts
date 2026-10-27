// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PaymasterSetup} from "./lib/PaymasterSetup.sol";

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {TornadoPaymaster} from "../contracts/tornadocash/TornadoPaymaster.sol";

/// Deploys the `TornadoPaymaster`. Run `SetupTornado` afterwards to allowlist instances.
contract DeployTornado is Script {
    function run() external returns (TornadoPaymaster paymaster) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        paymaster = deploy(privateKey);
        console.log("Deployed TornadoPaymaster at:", address(paymaster));
    }

    function deploy(uint256 privateKey) public returns (TornadoPaymaster) {
        (IEntryPoint entryPoint, IUniswapV3Factory factory, address weth, uint32 twapPeriod) = PaymasterSetup.baseArgs();

        vm.broadcast(privateKey);
        return new TornadoPaymaster(entryPoint, factory, weth, twapPeriod);
    }
}
