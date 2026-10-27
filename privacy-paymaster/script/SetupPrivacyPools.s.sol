// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Chains} from "./lib/Chains.sol";
import {PaymasterSetup} from "./lib/PaymasterSetup.sol";

import {PrivacyPoolsPaymaster} from "../contracts/privacypools/PrivacyPoolsPaymaster.sol";
import {IPrivacyPool} from "../contracts/privacypools/interfaces/IPrivacyPool.sol";

/// Allowlists every instance under `[protocols.privacy_pools.<name>]` in the
/// chain config on the `PrivacyPoolsPaymaster` at `PAYMASTER_ADDRESS`
contract SetupPrivacyPools is Script {
    function run() external {
        PrivacyPoolsPaymaster paymaster = PrivacyPoolsPaymaster(payable(vm.envAddress("PAYMASTER_ADDRESS")));
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        string memory toml = vm.readFile(Chains.path());
        // Friendly error if the chain config has no privacy pools section.
        require(
            vm.keyExistsToml(toml, ".protocols.privacy_pools"),
            "add [protocols.privacy_pools.<name>] entries to the chain config first"
        );
        string[] memory pools = vm.parseTomlKeys(toml, ".protocols.privacy_pools");
        require(pools.length > 0, "no privacy pools in chain config");

        for (uint256 i = 0; i < pools.length; i++) {
            allowPool(paymaster, string.concat("protocols.privacy_pools.", pools[i]), privateKey);
        }
    }

    function allowPool(PrivacyPoolsPaymaster paymaster, string memory tomlKey, uint256 privateKey) public {
        IPrivacyPool pool = IPrivacyPool(Chains.readAddress(tomlKey, "instance"));

        (bool allowed,) = paymaster.pools(pool);
        if (!allowed) {
            vm.broadcast(privateKey);
            paymaster.setPool(pool, true);
        }

        (, address asset) = paymaster.pools(pool);
        if (asset != address(0)) {
            PaymasterSetup.allowFeeToken(paymaster, asset, tomlKey, privateKey);
        }
    }
}
