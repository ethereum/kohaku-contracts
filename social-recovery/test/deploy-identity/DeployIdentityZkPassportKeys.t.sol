// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {DeployIdentityTestBase} from 'test/utils/DeployIdentityTestBase.sol';

/// @notice The eight trusted-key words the zkPassport method deploys with. The method reads them by position, so
///         a word in the wrong place routes proofs through the wrong contract or declares the wrong party to every
///         holder who reads the method's trusted parties.
contract DeployIdentityZkPassportKeysTest is DeployIdentityTestBase {
  /// For any table and inputs, zkPassportKeys answers eight words in the method's order: the accepted version,
  /// the root verifier, the sub-verifier, the verifier helper, the root registry, the root admin, the root guardian and
  /// the sub-verifier admin. `_seed` builds every address as a hash of a distinct label and the seed, and the
  /// version word from the seed.
  function test_WhenAnyTableAndInputsAreRendered(uint256 _seed) external view {
    IDeployIdentity.Pins memory _table = _pins;
    _table.acceptedVersion = bytes32((_seed >> 208) << 208);
    _table.rootVerifier = _freshAddress('anyRoot', _seed);
    _table.subVerifier = _freshAddress('anySubVerifier', _seed);
    _table.verifierHelper = _freshAddress('anyVerifierHelper', _seed);
    _table.rootRegistry = _freshAddress('anyRegistry', _seed);
    IDeployIdentity.Inputs memory _operator = IDeployIdentity.Inputs({
      zkPassportMethodSafe: _freshAddress('anyZkPassportMethodSafe', _seed),
      aadhaarMethodSafe: _freshAddress('anyAadhaarMethodSafe', _seed),
      rootAdmin: _freshAddress('anyRootAdmin', _seed),
      rootGuardian: _freshAddress('anyRootGuardian', _seed),
      subVerifierAdmin: _freshAddress('anySubVerifierAdmin', _seed)
    });
    bytes32[] memory _keys = _script.zkPassportKeys(_table, _operator);
    // it should answer eight words
    assertEq(_keys.length, _KEY_COUNT, 'word count');
    // it should place each value at its position, each address left-padded
    assertEq(_keys[0], _table.acceptedVersion, 'accepted version');
    assertEq(_keys[1], _word(_table.rootVerifier), 'root verifier');
    assertEq(_keys[2], _word(_table.subVerifier), 'sub-verifier');
    assertEq(_keys[3], _word(_table.verifierHelper), 'verifier helper');
    assertEq(_keys[4], _word(_table.rootRegistry), 'root registry');
    assertEq(_keys[5], _word(_operator.rootAdmin), 'root admin');
    assertEq(_keys[6], _word(_operator.rootGuardian), 'root guardian');
    assertEq(_keys[7], _word(_operator.subVerifierAdmin), 'sub-verifier admin');
  }

  /// For Sepolia's table, zkPassportKeys answers the published words: 0.21.1, then the root verifier, the
  /// sub-verifier, the verifier helper and the registry as left-padded words, then the three operator inputs. Neither
  /// method's Safe is among them, since a Safe holds roles and is no trusted key.
  function test_WhenSepoliasTableIsRendered() external view {
    bytes32[] memory _keys = _script.zkPassportKeys(_script.pinsFor(_SEPOLIA_CHAIN_ID), _inputs);
    // it should answer the published route and the operator's role words
    assertEq(_keys.length, _KEY_COUNT, 'word count');
    assertEq(_keys[0], 0x0000001500010000000000000000000000000000000000000000000000000000, 'accepted version');
    assertEq(_keys[1], 0x0000000000000000000000001d000001000efd9a6371f4d90bb8920d5431c0d8, 'root verifier');
    assertEq(_keys[2], 0x00000000000000000000000077cb76df1b37644126f8e04caa88356f78a61e47, 'sub-verifier');
    assertEq(_keys[3], 0x000000000000000000000000e8ae97ef2fff59597d1b6882286754fec200f3a9, 'verifier helper');
    assertEq(_keys[4], 0x0000000000000000000000001d0000020038d6e40e1d98e09fa1bb3a7daa8b70, 'root registry');
    assertEq(_keys[5], _word(_inputs.rootAdmin), 'root admin');
    assertEq(_keys[6], _word(_inputs.rootGuardian), 'root guardian');
    assertEq(_keys[7], _word(_inputs.subVerifierAdmin), 'sub-verifier admin');
  }

  /// A zero root guardian, the one word the method lets be zero, comes out as the zero word in position seven,
  /// so a root with no root guardian deploys with that fact declared rather than with some other address.
  function test_WhenTheRootGuardianIsZero() external view {
    IDeployIdentity.Inputs memory _operator = _inputs;
    _operator.rootGuardian = address(0);
    bytes32[] memory _keys = _script.zkPassportKeys(_pins, _operator);
    // it should answer the zero word as the root guardian
    assertEq(_keys[6], bytes32(0));
  }
}
