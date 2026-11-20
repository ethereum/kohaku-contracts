// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

// Fixtures for the TornadoPaymaster integration test: a local pool's creation bytecode and a matching deposit and withdrawal proof.
library TornadoFixtures {
    using stdJson for string;
    Vm constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));

    function loadCreationCode(string memory name) internal view returns (bytes memory) {
        string memory file = string.concat("test/fixtures/tornadocash-local/", name, ".creation.hex");
        return vm.parseBytes(vm.readFile(file));
    }

    function loadCommitment() internal view returns (bytes32) {
        string memory file = "test/fixtures/tornadocash-local/shield.json";
        string memory json = vm.readFile(file);
        return vm.parseJsonBytes32(json, ".commitment");
    }

    function loadProof() internal view returns (bytes memory) {
        string memory file = "test/fixtures/tornadocash-local/unshield.json";
        string memory json = vm.readFile(file);
        return vm.parseJsonBytes(json, ".proof");
    }

    function loadRoot() internal view returns (bytes32) {
        string memory file = "test/fixtures/tornadocash-local/unshield.json";
        string memory json = vm.readFile(file);
        return vm.parseJsonBytes32(json, ".root");
    }

    function loadNullifierHash() internal view returns (bytes32) {
        string memory file = "test/fixtures/tornadocash-local/unshield.json";
        string memory json = vm.readFile(file);
        return vm.parseJsonBytes32(json, ".nullifierHash");
    }

    function loadRecipient() internal view returns (address payable) {
        string memory file = "test/fixtures/tornadocash-local/unshield.json";
        string memory json = vm.readFile(file);
        return payable(vm.parseJsonAddress(json, ".recipient"));
    }

    function loadRelayer() internal view returns (address payable) {
        string memory file = "test/fixtures/tornadocash-local/unshield.json";
        string memory json = vm.readFile(file);
        return payable(vm.parseJsonAddress(json, ".relayer"));
    }

    function loadFee() internal view returns (uint256) {
        string memory file = "test/fixtures/tornadocash-local/unshield.json";
        string memory json = vm.readFile(file);
        return vm.parseJsonUint(json, ".fee");
    }

    //? Ignore in forge coverage
    function test() public {}
}
