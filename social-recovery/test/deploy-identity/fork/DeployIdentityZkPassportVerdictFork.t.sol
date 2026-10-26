// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';
import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {IZkPassportRootVerifier} from 'contracts/methods/zkpassport/IZkPassportRootVerifier.sol';
import {ZkPassportDigestBindFixture} from 'test/fixtures/zkpassport-digest/ZkPassportDigestBindFixture.sol';
import {DeployIdentityForkTestBase} from 'test/utils/DeployIdentityForkTestBase.sol';

/// @notice A positive verdict through the zkPassport method as the identity script deploys it. On a Sepolia fork
///         the script deploys the method with the table's words, and the method checks a real zkPassport 0.21.1
///         bind proof whose custom data is the method's rendering of one fixed digest. The live root verifier,
///         sub-verifier, Honk verifier, circuit root check and verifier helper all run; only the root registry's check
///         of the proof's certificate root is mocked, because upstream's generator signed the proof with a test
///         certificate no live registry holds. A magic value here shows that a deployed method, wired by the script
///         to the live route, accepts a proof that binds the recovery's digest. Each test skips cleanly when
///         SEPOLIA_RPC_URL is unset.
contract DeployIdentityZkPassportVerdictForkTest is DeployIdentityForkTestBase, ZkPassportDigestBindFixture {
  /// @notice The verification key hash under which the 0.21.1 sub-verifier registers its outer verifier for five
  ///         subproofs, the shape of the proof.
  bytes32 internal constant _VKEY_HASH = 0x14765cfe42f6c72ea39d5c9be96c3e9a39b2e982ec5f0133749f88e0f00bcc27;
  /// @notice The registry id the root verifier passes to isRootValid for certificate roots.
  bytes32 internal constant _CERTIFICATE_REGISTRY_ID = bytes32(uint256(1));
  /// @notice The service the proof is scoped to, which its public inputs commit to.
  string internal constant _DOMAIN = 'zkpassport.id';
  string internal constant _SCOPE = 'bigproof';
  /// @notice Thirty days, the validity the config asks for, longer than the gap from the proof's date to the fork.
  uint256 internal constant _VALIDITY = 30 days;

  IPolicyMethod internal _method;

  /// @notice Forks Sepolia, mocks the certificate root check for the proof's own root at the proof's own date, and
  ///         deploys the identity methods through the script with Sepolia's table and the live role words.
  function _deployOnSepolia() internal returns (bool _forked) {
    _forked = _forkSepolia();
    if (!_forked) return _forked;
    vm.mockCall(
      _ROOT_REGISTRY,
      abi.encodeCall(
        IDeployIdentityForkRootRegistry.isRootValid,
        (_CERTIFICATE_REGISTRY_ID, _ZK_DIGEST_BIND_PUBLIC_INPUT_0, uint256(_ZK_DIGEST_BIND_PUBLIC_INPUT_2))
      ),
      abi.encode(true)
    );
    IDeployIdentity.Pins memory _table = _script.pinsFor(block.chainid);
    _method = _script.deploy(_table, _liveInputs(_table)).zkPassportMethod;
  }

  /// @notice A config naming the proof's identifier, the second public input from the end, with the proof's
  ///         domain and scope and a thirty day validity.
  function _config() internal pure returns (bytes memory _encoded) {
    bytes32[] memory _publicInputs = _zkDigestBindPublicInputs();
    _encoded = abi.encode(_publicInputs[_publicInputs.length - 2], _DOMAIN, _SCOPE, _VALIDITY);
  }

  /// @notice The method proof: the outer proof with its verification key hash and public inputs, and the
  ///         committed inputs.
  function _proof() internal pure returns (bytes memory _encoded) {
    _encoded = abi.encode(
      IZkPassportRootVerifier.ProofVerificationData({
        vkeyHash: _VKEY_HASH, proof: _ZK_DIGEST_BIND_PROOF, publicInputs: _zkDigestBindPublicInputs()
      }),
      _ZK_DIGEST_BIND_COMMITTED_INPUTS
    );
  }

  /// The deployed method answers the magic value for the proof and the digest it binds.
  function test_WhenTheProofBindsTheDigest() external {
    if (!_deployOnSepolia()) return;
    // it should answer the magic value
    assertEq(_method.verify(_config(), _ZK_DIGEST_BIND_DIGEST, _proof()), IPolicyMethod.verify.selector);
  }

  /// The deployed method answers a word other than the magic value for the same proof and a digest whose
  /// rendering differs in its last hexadecimal character, so a bind proof approves one digest and no other.
  function test_WhenTheDigestDiffersInOneCharacter() external {
    if (!_deployOnSepolia()) return;
    bytes32 _otherDigest = bytes32(uint256(_ZK_DIGEST_BIND_DIGEST) ^ 1);
    // it should answer a word other than the magic value
    assertNotEq(_method.verify(_config(), _otherDigest, _proof()), IPolicyMethod.verify.selector);
  }
}

/// @notice The root registry call the live root verifier makes. These tests mock it for the proof's certificate
///         root alone.
interface IDeployIdentityForkRootRegistry {
  /// @notice Whether a root is valid in a registry at a timestamp.
  /// @param _registryId 1 for the certificate registry, 2 for the circuit registry.
  /// @param _root The root to check.
  /// @param _timestamp The proof's date.
  /// @return _valid True when the registry holds the root as valid at that date.
  function isRootValid(bytes32 _registryId, bytes32 _root, uint256 _timestamp) external view returns (bool _valid);
}
