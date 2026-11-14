// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PaymasterSetup} from "./lib/PaymasterSetup.sol";

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {TacitPaymaster} from "../contracts/tacit/TacitPaymaster.sol";

/// Deploys the `TacitPaymaster`. Run `SetupTacit` afterwards to allowlist pools.
///
/// A Tacit proof binds the relayer it was made for, so clients are configured with the paymaster's address: deploy
/// once, keep the address, and stake and fund it with `StakePaymaster`.
///
/// The owner is `PAYMASTER_OWNER` when set, otherwise the deploying key.
contract DeployTacit is Script {
    function run() external returns (TacitPaymaster paymaster) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        paymaster = deploy(privateKey);
        console.log("Deployed TacitPaymaster at:", address(paymaster));
    }

    function deploy(uint256 privateKey) public returns (TacitPaymaster) {
        (IEntryPoint entryPoint, IUniswapV3Factory factory, address weth, uint32 twapPeriod) = PaymasterSetup.baseArgs();

        address owner = vm.envOr("PAYMASTER_OWNER", vm.addr(privateKey));

        vm.broadcast(privateKey);
        return new TacitPaymaster(entryPoint, factory, weth, twapPeriod, owner);
    }
}
