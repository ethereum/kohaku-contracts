// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {BasePrivacyPaymaster} from "../../contracts/BasePrivacyPaymaster.sol";
import {Chains} from "./Chains.sol";

/// Shared deployment helpers for the per-protocol paymasters.
library PaymasterSetup {
    Vm constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));

    /// The constructor args shared by every paymaster, read from the chain config.
    function baseArgs()
        internal
        view
        returns (IEntryPoint entryPoint, IUniswapV3Factory factory, address weth, uint32 twapPeriod)
    {
        entryPoint = IEntryPoint(Chains.readAddress("protocols.erc4337", "entry_point"));
        factory = IUniswapV3Factory(Chains.readAddress("protocols.uniswap_v3", "factory"));
        weth = Chains.readAddress("tokens", "weth");
        twapPeriod = uint32(Chains.readUint("protocols.uniswap_v3", "twap_period"));
    }

    /// Allows `feeToken` on `paymaster` if it isn't already, reading the
    /// uniswap fee tier from `tomlKey`, and expands the uniswap pool's
    /// observation buffer to cover the TWAP period.
    function allowFeeToken(BasePrivacyPaymaster paymaster, address feeToken, string memory tomlKey, uint256 privateKey)
        internal
    {
        if (paymaster.oraclePools(feeToken) != address(0)) return;

        uint24 uniswapFee = uint24(Chains.readUint(tomlKey, "uniswap_fee"));
        vm.broadcast(privateKey);
        paymaster.setFeeToken(feeToken, uniswapFee, true);

        uint32 blockTime = uint32(Chains.readUint("block_time"));
        uint32 observations = paymaster.TWAP_PERIOD() / blockTime;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 requiredCardinality = uint16(observations) + 1;
        vm.broadcast(privateKey);
        IUniswapV3Pool(paymaster.oraclePools(feeToken)).increaseObservationCardinalityNext(requiredCardinality);
    }

    //? Ignore in forge coverage
    function test() public {}
}
