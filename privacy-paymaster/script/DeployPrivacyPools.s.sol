// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Deployments} from "./lib/Deployments.sol";
import {Chains} from "./lib/Chains.sol";
import {PaymasterSetup} from "./lib/PaymasterSetup.sol";

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {PrivacyPoolsPaymaster} from "../contracts/privacypools/PrivacyPoolsPaymaster.sol";
import {IPrivacyPool} from "../contracts/privacypools/interfaces/IPrivacyPool.sol";

/// Deploys the `PrivacyPoolsPaymaster` and allowlists every pool listed under
/// `[protocols.privacy_pools.<name>]` in the chain config, e.g.
///
///     [protocols.privacy_pools.simple_eth]
///     instance = "0x..."
///
///     [protocols.privacy_pools.complex_weth_3000]
///     instance = "0x..."
///     uniswap_fee = 3000
contract DeployPrivacyPools is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        string memory toml = vm.readFile(Chains.path());
        // Friendly error if the chain config has no privacy pools section.
        require(
            vm.keyExistsToml(toml, ".protocols.privacy_pools"),
            "add [protocols.privacy_pools.<name>] entries to the chain config first"
        );
        string[] memory pools = vm.parseTomlKeys(toml, ".protocols.privacy_pools");
        require(pools.length > 0, "no privacy pools in chain config");

        PrivacyPoolsPaymaster paymaster = deploy(privateKey);
        console.log("Deployed PrivacyPoolsPaymaster at:", address(paymaster));
        Deployments.writeAddress("privacypools", "paymaster", address(paymaster));

        for (uint256 i = 0; i < pools.length; i++) {
            allowPool(paymaster, string.concat("protocols.privacy_pools.", pools[i]), privateKey);
        }
    }

    function deploy(uint256 privateKey) public returns (PrivacyPoolsPaymaster) {
        (IEntryPoint entryPoint, IUniswapV3Factory factory, address weth, uint32 twapPeriod) =
            PaymasterSetup.baseArgs();

        vm.broadcast(privateKey);
        return new PrivacyPoolsPaymaster(entryPoint, factory, weth, twapPeriod);
    }

    function allowPool(PrivacyPoolsPaymaster paymaster, string memory tomlKey, uint256 privateKey) public {
        IPrivacyPool pool = IPrivacyPool(Chains.readAddress(tomlKey, "instance"));

        vm.broadcast(privateKey);
        paymaster.setPool(pool, true);

        (, address asset) = paymaster.pools(pool);
        if (asset != address(0)) {
            PaymasterSetup.allowFeeToken(paymaster, asset, tomlKey, privateKey);
        }
    }
}
