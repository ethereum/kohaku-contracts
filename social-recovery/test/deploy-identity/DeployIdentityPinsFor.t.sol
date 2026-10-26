// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {DeployIdentityTestBase} from 'test/utils/DeployIdentityTestBase.sol';

/// @notice The per-chain table the identity script reads every pin from. zkPassport ships on mainnet and Sepolia
///         with the reviewed 0.21.1 route of each chain, and Aadhaar on Sepolia alone. A wrong address here would
///         point a method at a contract nobody reviewed, so each value is compared with the published table.
contract DeployIdentityPinsForTest is DeployIdentityTestBase {
  /// pinsFor(1) holds version 0.21.1, mainnet's root verifier, 0.21.1 sub-verifier, verifier helper and root registry,
  /// and ships no Aadhaar method, so its verifier, code hash and key are zero. No Aadhaar verifier is published on
  /// mainnet.
  function test_WhenTheChainIsMainnet() external view {
    IDeployIdentity.Pins memory _table = _script.pinsFor(_MAINNET_CHAIN_ID);
    // it should pin version 0.21.1 and mainnet's zkPassport route
    assertEq(_table.acceptedVersion, _VERSION_0_21_1, 'accepted version');
    assertEq(_table.rootVerifier, _ROOT_VERIFIER, 'root verifier');
    assertEq(_table.subVerifier, _MAINNET_SUB_VERIFIER, 'sub-verifier');
    assertEq(_table.verifierHelper, _MAINNET_VERIFIER_HELPER, 'verifier helper');
    assertEq(_table.rootRegistry, _ROOT_REGISTRY, 'root registry');
    // it should ship no Aadhaar method
    assertFalse(_table.shipsAadhaar, 'ships Aadhaar');
    assertEq(_table.aadhaarVerifier, address(0), 'Aadhaar verifier');
    assertEq(_table.aadhaarVerifierCodehash, bytes32(0), 'Aadhaar verifier code hash');
    assertEq(_table.aadhaarKey, bytes32(0), 'Aadhaar key');
  }

  /// pinsFor(11155111) holds version 0.21.1, Sepolia's zkPassport route, and the Aadhaar method with the Sepolia
  /// Groth16 verifier, that verifier's code hash and the hash of UIDAI's current key, the values the Sepolia demo
  /// deploys with. The code hash lets the deployment tell the reviewed verifier from any other code.
  function test_WhenTheChainIsSepolia() external view {
    IDeployIdentity.Pins memory _table = _script.pinsFor(_SEPOLIA_CHAIN_ID);
    // it should pin version 0.21.1 and sepolia's zkPassport route
    assertEq(_table.acceptedVersion, _VERSION_0_21_1, 'accepted version');
    assertEq(_table.rootVerifier, _ROOT_VERIFIER, 'root verifier');
    assertEq(_table.subVerifier, _SEPOLIA_SUB_VERIFIER, 'sub-verifier');
    assertEq(_table.verifierHelper, _SEPOLIA_VERIFIER_HELPER, 'verifier helper');
    assertEq(_table.rootRegistry, _ROOT_REGISTRY, 'root registry');
    // it should ship the Aadhaar method with its verifier, its code hash and UIDAI's key
    assertTrue(_table.shipsAadhaar, 'ships Aadhaar');
    assertEq(_table.aadhaarVerifier, _SEPOLIA_AADHAAR_VERIFIER, 'Aadhaar verifier');
    assertEq(_table.aadhaarVerifierCodehash, _SEPOLIA_AADHAAR_VERIFIER_CODEHASH, 'Aadhaar verifier code hash');
    assertEq(_table.aadhaarKey, _UIDAI_KEY, 'Aadhaar key');
  }

  /// pinsFor reverts naming the chain for any id other than 1 and 11155111. `_raw` is mapped onto every chain id
  /// except those two, by skipping them rather than filtering the run, so an operator on an unknown chain gets
  /// no deployment with a guessed route.
  function test_RevertWhen_TheChainIsNotSupported(uint256 _raw) external {
    uint256 _chainId = bound(_raw, 0, type(uint256).max - 2);
    if (_chainId > _MAINNET_CHAIN_ID - 1) ++_chainId;
    if (_chainId > _SEPOLIA_CHAIN_ID - 1) ++_chainId;
    // it should revert
    // it should name the chain in the unsupported chain error
    vm.expectRevert(abi.encodeWithSelector(IDeployIdentity.DeployIdentity_UnsupportedChain.selector, _chainId));
    _script.pinsFor(_chainId);
  }

  /// pinsFor reverts for the ids right next to Sepolia's, the exact-equality boundary of the table's lookup, so a
  /// range check in place of an exact match fails here.
  function test_RevertWhen_TheChainIdNeighboursSepolia() external {
    // it should revert
    // it should name the chain in the unsupported chain error
    vm.expectRevert(
      abi.encodeWithSelector(IDeployIdentity.DeployIdentity_UnsupportedChain.selector, _SEPOLIA_CHAIN_ID - 1)
    );
    _script.pinsFor(_SEPOLIA_CHAIN_ID - 1);
    vm.expectRevert(
      abi.encodeWithSelector(IDeployIdentity.DeployIdentity_UnsupportedChain.selector, _SEPOLIA_CHAIN_ID + 1)
    );
    _script.pinsFor(_SEPOLIA_CHAIN_ID + 1);
  }

  /// pinsFor reverts for chain ids 0 and 2, the ids on each side of mainnet's. A table that treated an unset id
  /// as mainnet would deploy mainnet's route anywhere.
  function test_RevertWhen_TheChainIdNeighboursMainnet() external {
    // it should revert
    // it should name the chain in the unsupported chain error
    vm.expectRevert(abi.encodeWithSelector(IDeployIdentity.DeployIdentity_UnsupportedChain.selector, uint256(0)));
    _script.pinsFor(0);
    vm.expectRevert(abi.encodeWithSelector(IDeployIdentity.DeployIdentity_UnsupportedChain.selector, uint256(2)));
    _script.pinsFor(2);
  }
}
