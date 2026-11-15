// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Chains} from "./lib/Chains.sol";

import {TacitPaymaster} from "../contracts/tacit/TacitPaymaster.sol";
import {ITacitPool} from "../contracts/tacit/interfaces/ITacitPool.sol";

/// Allowlists every pool under `[protocols.tacit.<name>]` in the chain
/// config on the `TacitPaymaster` at `PAYMASTER_ADDRESS`.
contract SetupTacit is Script {
    function run() external {
        TacitPaymaster paymaster = TacitPaymaster(payable(vm.envAddress("PAYMASTER_ADDRESS")));
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        string memory toml = vm.readFile(Chains.path());
        string[] memory pools = vm.parseTomlKeys(toml, ".protocols.tacit");
        for (uint256 i = 0; i < pools.length; i++) {
            allowPool(paymaster, string.concat("protocols.tacit.", pools[i]), privateKey);
        }
    }

    function allowPool(TacitPaymaster paymaster, string memory tomlKey, uint256 privateKey) public {
        ITacitPool pool = ITacitPool(Chains.readAddress(tomlKey, "instance"));

        if (!paymaster.pools(pool)) {
            vm.broadcast(privateKey);
            paymaster.setPool(pool, true);
        }
    }
}
