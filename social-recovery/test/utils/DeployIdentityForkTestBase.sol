// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {DeployIdentity} from 'script/DeployIdentity.s.sol';
import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {DeployIdentityTestBase} from 'test/utils/DeployIdentityTestBase.sol';

/// @notice The reads of zkPassport's live root verifier these tests make to build a good operator input. They
///         follow upstream's RootVerifier, whose public state variables admin and guardian, holding the root
///         admin and the root guardian, compile to these getters.
interface IDeployIdentityForkRoot {
  /// @notice The root verifier's root admin.
  /// @return _rootAdmin The root admin.
  function admin() external view returns (address _rootAdmin);

  /// @notice The root verifier's root guardian, who may stop the root.
  /// @return _rootGuardian The root guardian, or address(0) when none is set.
  function guardian() external view returns (address _rootGuardian);
}

/// @notice The read of a live zkPassport sub-verifier these tests make to build a good operator input.
interface IDeployIdentityForkSubVerifier {
  /// @notice The sub-verifier's admin.
  /// @return _admin The admin.
  function admin() external view returns (address _admin);
}

/// @notice Shared setup for the identity deployment tests that need the real chains. Each test forks mainnet or
///         Sepolia at a pinned block, creates the script there, and skips cleanly when its endpoint is unset.
abstract contract DeployIdentityForkTestBase is DeployIdentityTestBase {
  /// @notice A finalized mainnet block, 2026-10-23, where zkPassport's root verifier routes version 0.21.1 to
  ///         the table's sub-verifier and verifier helper. Pinned so the tests do not depend on later chain state.
  uint256 internal constant _MAINNET_FORK_BLOCK = 26_255_983;
  /// @notice A Sepolia block of 2026-10-23, where the root verifier routes version 0.21.1 to the table's
  ///         sub-verifier and verifier helper. It comes after the date of the digest bind proof in
  ///         test/fixtures/zkpassport-digest, so the live sub-verifier reads that proof as already made.
  uint256 internal constant _SEPOLIA_FORK_BLOCK = 11_977_408;

  /// @notice Forks `_envName`'s endpoint at `_block` and creates the script there. Returns false, after marking
  ///         the test skipped, when the endpoint is unset.
  function _fork(string memory _envName, uint256 _block) internal returns (bool _forked) {
    string memory _url = vm.envOr(_envName, string(''));
    if (bytes(_url).length == 0) {
      vm.skip(true);
      return false;
    }
    vm.createSelectFork(_url, _block);
    _script = new DeployIdentity();
    _forked = true;
  }

  /// @notice Forks mainnet at the pinned block and creates the script there.
  function _forkMainnet() internal returns (bool _forked) {
    _forked = _fork('MAINNET_RPC_URL', _MAINNET_FORK_BLOCK);
  }

  /// @notice Forks Sepolia at the pinned block and creates the script there.
  function _forkSepolia() internal returns (bool _forked) {
    _forked = _fork('SEPOLIA_RPC_URL', _SEPOLIA_FORK_BLOCK);
  }

  /// @notice Good operator inputs for the forked chain: each method's Safe hashed from its own label, the Aadhaar
  ///         one left zero where the chain deploys no Aadhaar method, and the three role words read from the live
  ///         root verifier and the table's sub-verifier. The test reads them only to build an input the script's
  ///         comparison should accept; the script itself never fills them from the chain.
  function _liveInputs(IDeployIdentity.Pins memory _table)
    internal
    view
    returns (IDeployIdentity.Inputs memory _operator)
  {
    _operator = IDeployIdentity.Inputs({
      zkPassportMethodSafe: _freshAddress('forkZkPassportMethodSafe', 0),
      aadhaarMethodSafe: _table.shipsAadhaar ? _freshAddress('forkAadhaarMethodSafe', 0) : address(0),
      rootAdmin: IDeployIdentityForkRoot(_table.rootVerifier).admin(),
      rootGuardian: IDeployIdentityForkRoot(_table.rootVerifier).guardian(),
      subVerifierAdmin: IDeployIdentityForkSubVerifier(_table.subVerifier).admin()
    });
  }
}
