// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {ZkPassportMethod} from 'contracts/methods/zkpassport/ZkPassportMethod.sol';
import {IZkPassportRootVerifier} from 'contracts/methods/zkpassport/IZkPassportRootVerifier.sol';
import {IZkPassportVerifierHelper} from 'contracts/methods/zkpassport/IZkPassportVerifierHelper.sol';
import {ZkPassportBindFixture} from 'test/fixtures/zkpassport/ZkPassportBindFixture.sol';

/// @notice Checks the zkPassport method's copied ABI against zkPassport's contracts deployed on Sepolia, with
///         zkPassport's own 0.21.0 bind proof from zkpassport/circuits. Mocks cannot show that the copied structs, the
///         version word, the position of the identifier and of the nullifier type, and the verifier helper's return
///         layout match what is deployed; these tests can. The root verifier, the 0.21.0 sub-verifier, its Honk
///         verifier, the circuit root check and the verifier helper all run live. Only the root registry's check of the
///         certificate root is mocked, because a local test certificate signed the fixture.
/// @dev Each test skips cleanly when SEPOLIA_RPC_URL is unset. The fork needs an archive endpoint.
contract ZkPassportMethodForkTest is Test, ZkPassportBindFixture {
  /// @notice A finalized Sepolia block, 2026-10-02. At this block the root verifier routes 0.21.0 to the sub-verifier
  ///         and verifier helper below and is not paused, the sub-verifier registers the Honk verifier under the
  ///         fixture's verification key hash, and the fixture's circuit root is the latest in the circuit registry.
  ///         Pinned so the tests do not depend on later chain state.
  uint256 internal constant _SEPOLIA_BLOCK = 11_830_700;

  /// @notice zkPassport 0.21.0 as a version word: major, minor and patch as three big-endian uint16 values. It is
  ///         the version the method accepts, and the version the fixture was proved under.
  bytes32 internal constant _VERSION_0_21_0 = 0x0000001500000000000000000000000000000000000000000000000000000000;

  /// @notice zkPassport's root verifier, the same address on every chain.
  address internal constant _ROOT_VERIFIER = 0x1D000001000EFD9a6371f4d90bB8920D5431c0D8;
  /// @notice The sub-verifier the Sepolia root verifier routes 0.21.0 proofs to.
  address internal constant _SUB_VERIFIER = 0x78e111D6e8b655E5231ABAE8bFDC3e063084a5Ab;
  /// @notice The verifier helper the Sepolia root verifier returns for 0.21.0 proofs.
  address internal constant _VERIFIER_HELPER = 0xe8AE97eF2fFF59597D1B6882286754FEC200F3a9;
  /// @notice The registry the root verifier asks whether a certificate root or a circuit root is valid.
  address internal constant _ROOT_REGISTRY = 0x1D0000020038d6E40E1d98e09fA1bb3A7DAA8B70;
  /// @notice The root verifier's admin and the sub-verifier's admin at the pinned block. The root verifier has no
  ///         guardian there, so that trusted-key word is zero.
  address internal constant _UPSTREAM_ADMIN = 0x2000ab040a899f914D6DfD2457C3dFBB22d4c762;

  /// @notice The verification key hash under which the 0.21.0 sub-verifier registers its outer Honk verifier for
  ///         five subproofs, the shape of the fixture's proof. It is the five-subproof hash in
  ///         DeploySubVerifier.s.sol at the fixture's commit. Upstream's config.json labels the fixture with
  ///         0x2db02804..., which no deployed sub-verifier registers, so the root verifier would not find a verifier.
  bytes32 internal constant _VKEY_HASH = 0x2eae578482e200bb70139dbe6e49450b9082f50321be975fd86f0e768a85be9f;

  /// @notice The registry ids the root verifier passes to isRootValid: 1 for certificates, 2 for circuits.
  bytes32 internal constant _CERTIFICATE_REGISTRY_ID = bytes32(uint256(1));
  bytes32 internal constant _CIRCUIT_REGISTRY_ID = bytes32(uint256(2));

  /// @notice The service the fixture is scoped to. Public inputs 3 and 4 commit to them.
  string internal constant _DOMAIN = 'zkpassport.id';
  string internal constant _SCOPE = 'bigproof';
  /// @notice Thirty days, long enough to cover the gap from the fixture's date, 2026-09-15, to the pinned block.
  uint256 internal constant _VALIDITY = 30 days;

  /// @notice The identifier the live root verifier derives from the fixture, its scoped nullifier.
  bytes32 internal constant _FIXTURE_IDENTIFIER = 0x171de101deed3f056917faecfe6cc04db2ef02689a8a483962a688948ce44461;
  /// @notice The data the fixture binds, as upstream's generator wrote it.
  address internal constant _FIXTURE_SENDER = 0x04Fb06E8BF44eC60b6A99D2F98551172b2F2dED8;
  uint256 internal constant _FIXTURE_CHAIN_ID = 31_337;
  string internal constant _FIXTURE_CUSTOM_DATA = 'email:test@test.com,customer_id:1234567890';

  /// @notice The selector of the Honk verifier's error for a proof that fails its sumcheck.
  bytes4 internal constant _SUMCHECK_FAILED = bytes4(keccak256('SumcheckFailed()'));
  /// @notice A byte inside the proof's sumcheck section, which the corruption test flips.
  uint256 internal constant _CORRUPTED_BYTE = 5000;

  /// @notice A fixed digest. The fixture does not bind it, nor any other digest.
  bytes32 internal constant _DIGEST = keccak256('zkpassport fork digest');

  ZkPassportMethod internal _method;

  /// @notice Forks Sepolia at the pinned block, mocks the certificate root check, and deploys the method with the
  ///         live contracts in its trusted keys. Skips when SEPOLIA_RPC_URL is unset.
  /// @dev The mock answers true only for the fixture's own certificate root at the fixture's own date. That root is
  ///      a local test root no live registry holds. The circuit root is not mocked: it is the latest root of the
  ///      live circuit registry at the pinned block, which test_WhenTheLiveRegistryChecksTheFixtureRoots shows.
  ///      The method never calls the registry itself.
  function _forkSepolia() internal {
    _selectFork();
    vm.mockCall(
      _ROOT_REGISTRY,
      abi.encodeCall(
        IZkPassportForkRootRegistry.isRootValid,
        (_CERTIFICATE_REGISTRY_ID, _ZK_BIND_PUBLIC_INPUT_0, uint256(_ZK_BIND_PUBLIC_INPUT_2))
      ),
      abi.encode(true)
    );

    bytes32[] memory _keys = new bytes32[](8);
    _keys[0] = _VERSION_0_21_0;
    _keys[1] = _word(_ROOT_VERIFIER);
    _keys[2] = _word(_SUB_VERIFIER);
    _keys[3] = _word(_VERIFIER_HELPER);
    _keys[4] = _word(_ROOT_REGISTRY);
    _keys[5] = _word(_UPSTREAM_ADMIN);
    _keys[6] = bytes32(0);
    _keys[7] = _word(_UPSTREAM_ADMIN);
    _method = new ZkPassportMethod(makeAddr('forkPauseHolder'), makeAddr('forkKeyAdmin'), _keys);
  }

  /// @notice Forks Sepolia at the pinned block with no mock. Skips when SEPOLIA_RPC_URL is unset.
  function _selectFork() internal {
    string memory _url = vm.envOr('SEPOLIA_RPC_URL', string(''));
    if (bytes(_url).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(_url, _SEPOLIA_BLOCK);
  }

  function _word(address _account) internal pure returns (bytes32 _value) {
    _value = bytes32(uint256(uint160(_account)));
  }

  /// @notice The fixture's proof data, with `_proof` as the proof bytes.
  function _data(bytes memory _proof)
    internal
    pure
    returns (IZkPassportRootVerifier.ProofVerificationData memory _proofData)
  {
    _proofData = IZkPassportRootVerifier.ProofVerificationData({
      vkeyHash: _VKEY_HASH, proof: _proof, publicInputs: _zkBindPublicInputs()
    });
  }

  /// @notice The root verifier's parameters for `_proof`, built with the method's own structs, as the method
  ///         builds them: version 0.21.0 and development proofs refused.
  function _params(bytes memory _proof)
    internal
    pure
    returns (IZkPassportRootVerifier.ProofVerificationParams memory _rootParams)
  {
    _rootParams = IZkPassportRootVerifier.ProofVerificationParams({
      version: _VERSION_0_21_0,
      proofVerificationData: _data(_proof),
      committedInputs: _ZK_BIND_COMMITTED_INPUTS,
      serviceConfig: IZkPassportRootVerifier.ServiceConfig({
        validityPeriodInSeconds: _VALIDITY, domain: _DOMAIN, scope: _SCOPE, devMode: false
      })
    });
  }

  /// @notice A method config naming `_identifier` and the fixture's domain and scope, with a thirty day validity.
  ///         The config names no version.
  function _config(bytes32 _identifier) internal pure returns (bytes memory _encoded) {
    _encoded = abi.encode(_identifier, _DOMAIN, _SCOPE, _VALIDITY);
  }

  /// @notice A method proof carrying `_proof` and the fixture's public and committed inputs.
  function _methodProof(bytes memory _proof) internal pure returns (bytes memory _encoded) {
    _encoded = abi.encode(_data(_proof), _ZK_BIND_COMMITTED_INPUTS);
  }

  /*///////////////////////////////////////////////////////////////
                        THE LIVE CONTRACTS
  ///////////////////////////////////////////////////////////////*/

  /// At the pinned block the live root verifier routes 0.21.0 to the sub-verifier and verifier helper the method pins.
  /// The method trusts that route, so the fork must be one where it exists.
  function test_WhenTheLiveRootVerifierResolvesTheAcceptedVersion() external {
    _selectFork();
    // it should route the accepted version to the pinned sub-verifier
    assertEq(IZkPassportForkRoute(_ROOT_VERIFIER).getSubVerifier(_VERSION_0_21_0), _SUB_VERIFIER, 'sub-verifier');
    // it should name the pinned verifier helper for the accepted version
    assertEq(IZkPassportForkRoute(_ROOT_VERIFIER).getHelper(_VERSION_0_21_0), _VERIFIER_HELPER, 'verifier helper');
  }

  /// Unmocked, the live registry accepts the fixture's circuit root at the fixture's date and refuses its
  /// certificate root. The certificate root check is therefore the only one the other tests need to mock.
  function test_WhenTheLiveRegistryChecksTheFixtureRoots() external {
    _selectFork();
    IZkPassportForkRootRegistry _registry = IZkPassportForkRootRegistry(_ROOT_REGISTRY);
    uint256 _proofDate = uint256(_ZK_BIND_PUBLIC_INPUT_2);
    // it should accept the circuit root
    assertTrue(
      _registry.isRootValid(_CIRCUIT_REGISTRY_ID, _ZK_BIND_PUBLIC_INPUT_1, _proofDate), 'the live circuit root'
    );
    // it should refuse the certificate root
    assertFalse(
      _registry.isRootValid(_CERTIFICATE_REGISTRY_ID, _ZK_BIND_PUBLIC_INPUT_0, _proofDate), 'the test certificate root'
    );
  }

  /// The live root verifier accepts the fixture when called through the method's own structs, with the 0.21.0
  /// version word and development proofs refused. It returns the fixture's identifier and the Sepolia verifier helper
  /// the method pins, so a struct or version word copied wrongly into the method would fail here.
  function test_WhenTheLiveRootVerifierChecksTheFixture() external {
    _forkSepolia();
    (bool _valid, bytes32 _identifier, IZkPassportVerifierHelper _verifierHelper) =
      IZkPassportRootVerifier(_ROOT_VERIFIER).verify(_params(_ZK_BIND_PROOF));
    // it should answer valid
    assertTrue(_valid, 'the live root verifier accepts the fixture');
    // it should return the fixture's identifier
    assertEq(_identifier, _FIXTURE_IDENTIFIER, 'the identifier the live root verifier derives');
    // it should return the pinned sepolia verifier helper
    assertEq(
      address(_verifierHelper), _VERIFIER_HELPER, 'the verifier helper the live root verifier returns for 0.21.0'
    );
  }

  /// The live verifier helper decodes the fixture's committed inputs, through the method's own BoundData struct, into
  /// the sender, chain id and custom data upstream bound. The method reads the digest from that custom data, so the
  /// copied return layout must match the deployed verifier helper.
  function test_WhenTheLiveVerifierHelperReadsTheFixtureCommittedInputs() external {
    _forkSepolia();
    IZkPassportVerifierHelper.BoundData memory _bound =
      IZkPassportVerifierHelper(_VERIFIER_HELPER).getBoundData(_ZK_BIND_COMMITTED_INPUTS);
    // it should return the fixture's sender, chain id and custom data
    assertEq(_bound.senderAddress, _FIXTURE_SENDER, 'the bound sender');
    assertEq(_bound.chainId, _FIXTURE_CHAIN_ID, 'the bound chain id');
    assertEq(_bound.customData, _FIXTURE_CUSTOM_DATA, 'the bound custom data');
  }

  /// The method reads the nullifier type third from the end of the public inputs and compares the identifier the
  /// root verifier returns. On a real proof the third from the end is zero, the non-salted type the method
  /// requires, and the returned identifier is the scoped nullifier second from the end.
  function test_WhenTheFixturePublicInputsAreReadWhereTheMethodReadsThem() external {
    _forkSepolia();
    bytes32[] memory _inputs = _zkBindPublicInputs();
    (, bytes32 _identifier,) = IZkPassportRootVerifier(_ROOT_VERIFIER).verify(_params(_ZK_BIND_PROOF));
    // it should hold nullifier type zero third from the end
    assertEq(_inputs[_inputs.length - 3], bytes32(0), 'the nullifier type, third public input from the end');
    // it should hold the identifier the root returns second from the end
    assertEq(_identifier, _inputs[_inputs.length - 2], 'the identifier is the second public input from the end');
  }

  /*///////////////////////////////////////////////////////////////
                         THE METHOD ON A FORK
  ///////////////////////////////////////////////////////////////*/

  /// The method, wired to the live contracts and configured with the fixture's identifier, sends the live root
  /// verifier the accepted version and the parameters it accepts, and passes the committed inputs to the live
  /// verifier helper. It then answers zero, because the fixture binds an email string rather than the digest's
  /// rendering, so no foreign bind proof approves a recovery.
  function test_WhenTheMethodChecksTheFixtureAgainstItsOwnIdentifier() external {
    _forkSepolia();
    // it should send the root verifier the accepted version and a service config ending in false
    vm.expectCall(_ROOT_VERIFIER, abi.encodeCall(IZkPassportRootVerifier.verify, (_params(_ZK_BIND_PROOF))), 1);
    // it should pass the committed inputs to the live verifier helper
    vm.expectCall(
      _VERIFIER_HELPER, abi.encodeCall(IZkPassportVerifierHelper.getBoundData, (_ZK_BIND_COMMITTED_INPUTS)), 1
    );
    // it should answer zero because the custom data is not the digest's rendering
    bytes4 _answer = _method.verify(_config(_FIXTURE_IDENTIFIER), _DIGEST, _methodProof(_ZK_BIND_PROOF));
    assertEq(_answer, bytes4(0), 'the method refuses a proof that binds other custom data');
  }

  /// The method, configured with an identifier other than the one the live root verifier derives, answers zero
  /// without calling the verifier helper. A valid proof made with another document approves nothing.
  function test_WhenTheMethodChecksTheFixtureAgainstAnotherIdentifier() external {
    _forkSepolia();
    bytes32 _otherIdentifier = bytes32(uint256(_FIXTURE_IDENTIFIER) ^ 1);
    // it should not call the verifier helper
    vm.expectCall(_VERIFIER_HELPER, abi.encodeWithSelector(IZkPassportVerifierHelper.getBoundData.selector), 0);
    // it should answer zero
    bytes4 _answer = _method.verify(_config(_otherIdentifier), _DIGEST, _methodProof(_ZK_BIND_PROOF));
    assertEq(_answer, bytes4(0), 'the method refuses a proof of another document');
  }

  /// One flipped bit in the proof's sumcheck section makes the live Honk verifier reject the proof, and the root
  /// verifier reverts with its error. The method lets the revert through, which the manager reads as a refusal,
  /// so a tampered proof never approves a recovery.
  function test_RevertWhen_AProofByteIsCorrupted() external {
    _forkSepolia();
    bytes memory _corrupted = _ZK_BIND_PROOF;
    _corrupted[_CORRUPTED_BYTE] = _corrupted[_CORRUPTED_BYTE] ^ 0x01;
    // it should revert
    // it should fail in the live root verifier with the sumcheck error
    vm.expectRevert(abi.encodeWithSelector(_SUMCHECK_FAILED));
    IZkPassportRootVerifier(_ROOT_VERIFIER).verify(_params(_corrupted));
    // it should pass the same error out of the method, which the manager reads as a refusal
    vm.expectRevert(abi.encodeWithSelector(_SUMCHECK_FAILED));
    _method.verify(_config(_FIXTURE_IDENTIFIER), _DIGEST, _methodProof(_corrupted));
  }
}

/// @notice The two route reads of the root verifier the route test makes.
interface IZkPassportForkRoute {
  /// @notice The sub-verifier the root verifier routes a version to.
  /// @param _version The version word.
  /// @return _subVerifier The sub-verifier address.
  function getSubVerifier(bytes32 _version) external view returns (address _subVerifier);

  /// @notice The verifier helper the root verifier names for a version.
  /// @param _version The version word.
  /// @return _verifierHelper The verifier helper address.
  function getHelper(bytes32 _version) external view returns (address _verifierHelper);
}

/// @notice The root registry call the live root verifier makes. The tests mock it for the certificate root only.
interface IZkPassportForkRootRegistry {
  /// @notice Whether a root is valid in a registry at a timestamp.
  /// @param _registryId 1 for the certificate registry, 2 for the circuit registry.
  /// @param _root The root to check.
  /// @param _timestamp The proof's date.
  /// @return _valid True when the registry holds the root as valid at that date.
  function isRootValid(bytes32 _registryId, bytes32 _root, uint256 _timestamp) external view returns (bool _valid);
}
