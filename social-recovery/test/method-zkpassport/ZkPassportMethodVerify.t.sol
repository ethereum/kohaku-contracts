// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';
import {ZkPassportMethod} from 'contracts/methods/zkpassport/ZkPassportMethod.sol';
import {
  MethodZkPassportVerifierHelperMock,
  MethodZkPassportMockMode,
  MethodZkPassportProofVerificationData,
  MethodZkPassportProofVerificationParams,
  MethodZkPassportRootVerifierMock
} from 'test/mocks/MethodZkPassportMocks.sol';
import {MethodZkPassportFixture} from 'test/utils/MethodZkPassportFixture.sol';

/// @notice Tests the six checks the zkPassport method's verify runs in order. Mocks stand in for zkPassport's root
///         verifier and verifier helper. A proof is accepted only when the static call succeeds and returns exactly the
///         verify selector. The manager reads any other answer as a refusal.
contract ZkPassportMethodVerifyTest is MethodZkPassportFixture {
  /// @notice zkPassport 0.22.0 as a version word. The key admin moves the accepted version to it in the tests of a
  ///         rotation.
  bytes32 internal constant _ZK_VERSION_0_22_0 = 0x0000001600000000000000000000000000000000000000000000000000000000;

  /*///////////////////////////////////////////////////////////////
                           ALL SIX PASS
  ///////////////////////////////////////////////////////////////*/

  /// A proof that passes all six checks returns the verify selector. An honest identity proof counts toward a
  /// recovery.
  function test_WhenAllSixChecksPass() external {
    // it should return the verify selector
    bytes memory _proof = _zkDefaultHonestProof();
    _zkAssertAccepted(_zkDefaultConfig(), _defaultDigest, _proof);
    assertEq(_method.verify(_zkDefaultConfig(), _defaultDigest, _proof), IPolicyMethod.verify.selector);
  }

  /// The root verifier is called once, with the accepted version and a service config whose last field is false.
  /// That field allows development proofs. A development proof needs no real document, and the method never allows
  /// one.
  function test_WhenTheProofReachesTheRootVerifier() external {
    // it should call it once with the accepted version and a service config ending in false
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetHonestAnswers(_data, _defaultDigest);
    MethodZkPassportProofVerificationParams memory _params = _zkParams(
      _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
    );
    vm.expectCall(address(_rootMock), _zkRootCall(_params), 1);
    _zkAssertAccepted(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// The verifier helper receives exactly the proof's committed inputs. The digest is then read from data the proof
  /// commits to. A submitter cannot pick those bytes.
  function test_WhenTheProofReachesTheVerifierHelper() external {
    // it should pass the proofs committed inputs to get bound data
    bytes memory _proof = _zkDefaultHonestProof();
    vm.expectCall(
      address(_verifierHelperMock),
      abi.encodeCall(MethodZkPassportVerifierHelperMock.getBoundData, (_defaultCommittedInputs)),
      1
    );
    _zkAssertAccepted(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /*///////////////////////////////////////////////////////////////
                         THE CONFIGURED IDENTIFIER
  ///////////////////////////////////////////////////////////////*/

  /// A config with a zero identifier is refused, and neither mock is called. The root mock here would accept a zero
  /// identifier. The refusal therefore comes from the method. A credential must name a document.
  function test_WhenTheConfiguredIdentifierIsZero() external {
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    MethodZkPassportProofVerificationParams memory _params = _zkParams(
      _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
    );
    _zkSetAnswers(
      _rootMock, _verifierHelperMock, _params, true, bytes32(0), address(_verifierHelperMock), _zkRender(_defaultDigest)
    );
    // it should call no verifier
    vm.expectCall(address(_rootMock), abi.encodeWithSelector(MethodZkPassportRootVerifierMock.verify.selector), 0);
    vm.expectCall(
      address(_verifierHelperMock), abi.encodeWithSelector(MethodZkPassportVerifierHelperMock.getBoundData.selector), 0
    );
    // it should refuse the proof
    _zkAssertRefused(
      _zkConfig(bytes32(0), _defaultDomain, _defaultScope, _defaultValidity),
      _defaultDigest,
      _zkProof(_data, _defaultCommittedInputs)
    );
  }

  /*///////////////////////////////////////////////////////////////
                        THE ROOT VERIFIER CALL
  ///////////////////////////////////////////////////////////////*/

  /// A proof the root verifier accepts only as a development proof is refused. The method always asks with the
  /// development flag off. A proof made without a real document cannot recover an account.
  function test_WhenTheRootAcceptsTheProofOnlyAsADevelopmentProof() external {
    // it should refuse the proof
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _zkParams(
        _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, true
      ),
      true,
      _defaultIdentifier,
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// When the root verifier answers valid false, the proof is refused and the verifier helper is never called. The
  /// checks stop at the first failure.
  function test_WhenTheRootAnswersValidFalse() external {
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _zkParams(
        _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
      ),
      false,
      _defaultIdentifier,
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );
    // it should not call the verifier helper
    vm.expectCall(
      address(_verifierHelperMock), abi.encodeWithSelector(MethodZkPassportVerifierHelperMock.getBoundData.selector), 0
    );
    // it should refuse the proof
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// When the root verifier reverts, the proof is refused. A failed outside call never counts as approval.
  function test_WhenTheRootVerifierFails() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _rootMock.setMode(MethodZkPassportMockMode.Revert);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// When the root verifier returns no data, the proof is refused. An empty answer never counts as approval.
  function test_WhenTheRootVerifierReturnsNothing() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _rootMock.setMode(MethodZkPassportMockMode.ReturnNothing);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// When the root verifier returns one true word, the proof is refused. The answer is shorter than its three fields.
  function test_WhenTheRootVerifierReturnsOneWord() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _rootMock.setMode(MethodZkPassportMockMode.ReturnOneWord);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// When the root verifier returns eight words of 0xff, the proof is refused. The answer is longer than an honest
  /// one and its words are not a clean boolean, identifier and address.
  function test_WhenTheRootVerifierReturnsOversizedGarbage() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _rootMock.setMode(MethodZkPassportMockMode.ReturnGarbage);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// When the method is deployed with a root verifier word naming an address with no code, the proof is refused. A
  /// call there returns nothing, and the router is fixed at deployment, so no later rotation can move it.
  function test_WhenTheRootVerifierWordHoldsNoCode() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _method =
      new ZkPassportMethod(_pauseHolder, _keyAdmin, _zkKeys(makeAddr('rootWithoutCode'), address(_verifierHelperMock)));
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /*///////////////////////////////////////////////////////////////
                  THE RETURNED IDENTIFIER AND VERIFIER HELPER
  ///////////////////////////////////////////////////////////////*/

  /// When the root verifier answers valid with a zero identifier, the proof is refused before the verifier helper is
  /// called. A proof that names no document cannot approve a recovery.
  function test_WhenTheReturnedIdentifierIsZero() external {
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _zkParams(
        _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
      ),
      true,
      bytes32(0),
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );
    // it should not call the verifier helper
    vm.expectCall(
      address(_verifierHelperMock), abi.encodeWithSelector(MethodZkPassportVerifierHelperMock.getBoundData.selector), 0
    );
    // it should refuse the proof
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// When the root verifier answers valid for another identifier, the proof is refused before the verifier helper is
  /// called. One person's passport cannot approve a recovery set up for another person.
  function test_WhenTheReturnedIdentifierDiffersFromTheConfig() external {
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _zkParams(
        _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
      ),
      true,
      bytes32(uint256(_defaultIdentifier) + 1),
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );
    // it should not call the verifier helper
    vm.expectCall(
      address(_verifierHelperMock), abi.encodeWithSelector(MethodZkPassportVerifierHelperMock.getBoundData.selector), 0
    );
    // it should refuse the proof
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// When the root verifier answers valid for an identifier that differs from the configured one only in bit 200,
  /// the proof is refused. A document identifier is a field element that fills the whole word, so the method must
  /// compare all 256 bits, not only the low ones an address would hold.
  function test_WhenTheReturnedIdentifierDiffersOnlyInItsHighBits() external {
    // it should refuse the proof
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _zkParams(
        _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
      ),
      true,
      bytes32(uint256(_defaultIdentifier) ^ (uint256(1) << 200)),
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// When the root verifier names a verifier helper other than the stored one, the proof is refused.
  /// That verifier helper is never called, even though it would bind the digest. A root verifier
  /// answer cannot pick its own verifier helper.
  function test_WhenTheReturnedVerifierHelperIsNotTheStoredVerifierHelper() external {
    MethodZkPassportVerifierHelperMock _otherVerifierHelper = new MethodZkPassportVerifierHelperMock();
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetAnswers(
      _rootMock,
      _otherVerifierHelper,
      _zkParams(
        _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
      ),
      true,
      _defaultIdentifier,
      address(_otherVerifierHelper),
      _zkRender(_defaultDigest)
    );
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), _zkRender(_defaultDigest));
    // it should not call the returned verifier helper
    vm.expectCall(
      address(_otherVerifierHelper), abi.encodeWithSelector(MethodZkPassportVerifierHelperMock.getBoundData.selector), 0
    );
    // it should refuse the proof
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// When the root verifier names the zero address as verifier helper, the proof is refused.
  function test_WhenTheReturnedVerifierHelperIsTheZeroAddress() external {
    // it should refuse the proof
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _zkParams(
        _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
      ),
      true,
      _defaultIdentifier,
      address(0),
      _zkRender(_defaultDigest)
    );
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /*///////////////////////////////////////////////////////////////
                         THE NULLIFIER TYPE
  ///////////////////////////////////////////////////////////////*/

  /// A nonzero nullifier type, the third public input from the end, is refused. The root verifier is called once
  /// and the verifier helper never. This check runs between the two calls. Only the unsalted type, zero, ties the
  /// identifier to the document.
  function test_WhenTheNullifierTypeInputIsNotZero() external {
    bytes32[] memory _inputs = _zkPublicInputs(8);
    _inputs[5] = bytes32(uint256(1));
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_inputs);
    _zkSetHonestAnswers(_data, _defaultDigest);
    // it should call the root verifier once
    vm.expectCall(address(_rootMock), abi.encodeWithSelector(MethodZkPassportRootVerifierMock.verify.selector), 1);
    // it should not call the verifier helper
    vm.expectCall(
      address(_verifierHelperMock), abi.encodeWithSelector(MethodZkPassportVerifierHelperMock.getBoundData.selector), 0
    );
    // it should refuse the proof
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// A proof of nullifier type NONE, four, is refused even when the root verifier answers the configured nonzero
  /// identifier. zkPassport 0.21.0 added that type for proofs that name no document, so the method refuses it on
  /// the type itself, not only on the zero identifier such proofs carry.
  function test_WhenTheNullifierTypeIsNoneAndTheIdentifierMatches() external {
    // it should refuse the proof
    bytes32[] memory _inputs = _zkPublicInputs(8);
    _inputs[5] = bytes32(uint256(4));
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_inputs);
    _zkSetHonestAnswers(_data, _defaultDigest);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// A nullifier type input that is zero in its low 160 bits and nonzero only in bit 200 is refused. The method
  /// must read the whole word as nonzero, since only a word that is zero throughout is the unsalted type.
  function test_WhenTheNullifierTypeInputIsNonzeroOnlyInItsHighBits() external {
    // it should refuse the proof
    bytes32[] memory _inputs = _zkPublicInputs(8);
    _inputs[5] = bytes32(uint256(1) << 200);
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_inputs);
    _zkSetHonestAnswers(_data, _defaultDigest);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// Zeroes at other positions do not stand in for the nullifier type. The method reads that one position.
  function test_WhenOnlyAnotherInputIsZero() external {
    // it should refuse the proof
    bytes32[] memory _inputs = _zkPublicInputs(8);
    _inputs[5] = bytes32(uint256(2));
    _inputs[0] = bytes32(0);
    _inputs[4] = bytes32(0);
    _inputs[6] = bytes32(0);
    _inputs[7] = bytes32(0);
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_inputs);
    _zkSetHonestAnswers(_data, _defaultDigest);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// With exactly three public inputs the nullifier type is the first. A zero there is accepted. The shortest list
  /// that holds a nullifier type works.
  function test_WhenThereAreExactlyThreePublicInputsAndTheFirstIsZero() external {
    // it should accept the proof
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(3));
    assertEq(_data.publicInputs[0], bytes32(0));
    _zkSetHonestAnswers(_data, _defaultDigest);
    _zkAssertAccepted(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// Two public inputs cannot hold a nullifier type. The proof is refused and the verifier helper is never called.
  function test_WhenThereAreTwoPublicInputs() external {
    MethodZkPassportProofVerificationData memory _data = _zkProofData(new bytes32[](2));
    _zkSetHonestAnswers(_data, _defaultDigest);
    // it should not call the verifier helper
    vm.expectCall(
      address(_verifierHelperMock), abi.encodeWithSelector(MethodZkPassportVerifierHelperMock.getBoundData.selector), 0
    );
    // it should refuse the proof
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /*///////////////////////////////////////////////////////////////
                           THE CUSTOM DATA
  ///////////////////////////////////////////////////////////////*/

  /// The digest rendered in uppercase is refused. Only one text form counts, and the SDK writes that form.
  function test_WhenCustomDataIsTheUppercaseRendering() external {
    // it should refuse the proof
    bytes32 _digest = 0xabcdef00abcdef00abcdef00abcdef00abcdef00abcdef00abcdef00abcdef00;
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), _zkRenderUpper(_digest));
    _zkAssertRefused(_zkDefaultConfig(), _digest, _proof);
  }

  /// The digest rendered without its 0x prefix is refused.
  function test_WhenCustomDataIsTheUnprefixedRendering() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), _zkRenderUnprefixed(_defaultDigest));
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// The digest rendered with an uppercase 0X prefix is refused.
  function test_WhenCustomDataCarriesAnUppercaseXInThePrefix() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(
      keccak256(_defaultCommittedInputs), string.concat('0X', _zkRenderUnprefixed(_defaultDigest))
    );
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// The correct rendering followed by one more character is refused. A prefix match is not enough.
  function test_WhenCustomDataCarriesATrailingCharacter() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), string.concat(_zkRender(_defaultDigest), ' '));
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// Empty custom data is refused. A proof that binds nothing approves nothing.
  function test_WhenCustomDataIsEmpty() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), '');
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// The digest's raw 32 bytes as custom data are refused. Only the text rendering counts.
  function test_WhenCustomDataIsTheRawDigestBytes() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), string(abi.encodePacked(_defaultDigest)));
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// A digest with leading zeroes is accepted in its full sixty four character rendering. The method keeps the
  /// leading zeroes in the text.
  function test_WhenTheDigestHasLeadingZeros() external {
    // it should accept the full width rendering
    bytes32 _digest = bytes32(uint256(1));
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), _zkRender(_digest));
    _zkAssertAccepted(_zkDefaultConfig(), _digest, _proof);
  }

  /// The short rendering 0x1 of a digest with leading zeroes is refused.
  function test_WhenCustomDataIsTheShortRenderingOfADigestWithLeadingZeros() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), '0x1');
    _zkAssertRefused(_zkDefaultConfig(), bytes32(uint256(1)), _proof);
  }

  /// The zero digest is accepted in its rendering of 0x and sixty four zeroes.
  function test_WhenTheDigestIsZero() external {
    // it should accept the rendering with sixty four zeros
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), _zkRender(bytes32(0)));
    _zkAssertAccepted(_zkDefaultConfig(), bytes32(0), _proof);
  }

  /// When the verifier helper reverts, the proof is refused.
  function test_WhenTheVerifierHelperFails() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setMode(MethodZkPassportMockMode.Revert);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// When the verifier helper returns no data, the proof is refused.
  function test_WhenTheVerifierHelperReturnsNothing() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setMode(MethodZkPassportMockMode.ReturnNothing);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// When the verifier helper returns one word, the proof is refused. One word cannot hold the bound data.
  function test_WhenTheVerifierHelperReturnsOneWord() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setMode(MethodZkPassportMockMode.ReturnOneWord);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// When the verifier helper returns eight words of 0xff, the proof is refused. Every offset in that answer is out of
  /// range.
  function test_WhenTheVerifierHelperReturnsOversizedGarbage() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setMode(MethodZkPassportMockMode.ReturnGarbage);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /*///////////////////////////////////////////////////////////////
                          MALFORMED INPUT
  ///////////////////////////////////////////////////////////////*/

  /// An empty proof is refused.
  function test_WhenTheProofIsEmpty() external {
    // it should refuse the proof
    _zkDefaultHonestProof();
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, '');
  }

  /// An empty config is refused.
  function test_WhenTheConfigIsEmpty() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _zkAssertRefused('', _defaultDigest, _proof);
  }

  /*///////////////////////////////////////////////////////////////
                             THE STOP
  ///////////////////////////////////////////////////////////////*/

  /// Verify gives the same answer before, during and after a stop. Only the manager reads the stop. A holder who
  /// opted out of stops can still recover while the method is stopped.
  function test_WhenTheMethodIsStoppedAndLifted() external {
    // it should give the same answer before, during and after the stop
    bytes memory _proof = _zkDefaultHonestProof();
    bytes memory _config = _zkDefaultConfig();
    _zkAssertAccepted(_config, _defaultDigest, _proof);
    vm.prank(_pauseHolder);
    _method.pause();
    assertTrue(_method.paused());
    _zkAssertAccepted(_config, _defaultDigest, _proof);
    vm.prank(_pauseHolder);
    _method.unpause();
    _zkAssertAccepted(_config, _defaultDigest, _proof);
  }

  /// A failing proof is still refused during a stop. A stop never turns a refusal into approval.
  function test_WhenAFailingProofArrivesDuringAStop() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    vm.prank(_pauseHolder);
    _method.pause();
    _zkAssertRefused(_zkDefaultConfig(), bytes32(uint256(_defaultDigest) ^ 1), _proof);
  }

  /*///////////////////////////////////////////////////////////////
                     WHICH WORDS A PROOF READS
  ///////////////////////////////////////////////////////////////*/

  /// After any rotation the key admin can make, which moves the version, the helper pin and the snapshots, verify
  /// still calls the root verifier the constructor took from the initial list, once, and accepts through the new
  /// helper. The router is the one value the key admin cannot redirect. `_release` builds any nonzero canonical
  /// version word, and each snapshot seed any clean address, nonzero except for the guardian.
  function test_WhenAnyRotationIsAccepted(
    uint256 _release,
    uint256 _subVerifier,
    uint256 _registry,
    uint256 _rootAdmin,
    uint256 _rootGuardian,
    uint256 _subVerifierAdmin
  ) external {
    MethodZkPassportVerifierHelperMock _newVerifierHelper = new MethodZkPassportVerifierHelperMock();
    bytes32 _version = bytes32(bound(_release, 1, type(uint48).max) << 208);
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_newVerifierHelper));
    _keys[_WORD_VERSION] = _version;
    _keys[_WORD_SUB_VERIFIER] = bytes32(bound(_subVerifier, 1, type(uint160).max));
    _keys[_WORD_REGISTRY] = bytes32(bound(_registry, 1, type(uint160).max));
    _keys[_WORD_ROOT_ADMIN] = bytes32(bound(_rootAdmin, 1, type(uint160).max));
    _keys[_WORD_ROOT_GUARDIAN] = bytes32(bound(_rootGuardian, 0, type(uint160).max));
    _keys[_WORD_SUB_VERIFIER_ADMIN] = bytes32(bound(_subVerifierAdmin, 1, type(uint160).max));
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_keys);

    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    MethodZkPassportProofVerificationParams memory _params =
      _zkParams(_version, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false);
    _zkSetAnswers(
      _rootMock,
      _newVerifierHelper,
      _params,
      true,
      _defaultIdentifier,
      address(_newVerifierHelper),
      _zkRender(_defaultDigest)
    );

    // it should call the root verifier fixed at deployment once
    vm.expectCall(address(_rootMock), _zkRootCall(_params), 1);
    // it should accept the proof
    _zkAssertAccepted(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// Once the keys name a new verifier helper, a root verifier answer naming the former verifier helper is refused.
  function test_WhenTheKeysNameAnotherVerifierHelper() external {
    // it should refuse a root answer naming the former verifier helper
    MethodZkPassportVerifierHelperMock _newVerifierHelper = new MethodZkPassportVerifierHelperMock();
    bytes memory _proof = _zkDefaultHonestProof();
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_zkKeys(address(_rootMock), address(_newVerifierHelper)));
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// A config committed while 0.21.0 is accepted still verifies after the key admin moves the accepted version to
  /// 0.22.0, and the root verifier receives 0.22.0. zkPassport retires an old route about every release, so a
  /// rotation must not strand a holder whose credential was committed before it.
  function test_WhenTheKeyAdminMovesTheAcceptedVersionAfterAConfigIsCommitted() external {
    bytes memory _committedConfig = _zkDefaultConfig();
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    MethodZkPassportProofVerificationParams memory _params = _zkParams(
      _ZK_VERSION_0_22_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
    );
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _params,
      true,
      _defaultIdentifier,
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_VERSION] = _ZK_VERSION_0_22_0;
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_keys);

    // it should call the root verifier once with the new accepted version
    vm.expectCall(address(_rootMock), _zkRootCall(_params), 1);
    // it should accept the proof
    _zkAssertAccepted(_committedConfig, _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// After the key admin moves the accepted version, a proof the root verifier accepts only under the former version
  /// is refused. The method routes every proof with the version it accepts now, never an older one.
  function test_WhenTheRootAcceptsTheProofOnlyUnderTheFormerVersion() external {
    // it should refuse the proof
    bytes memory _proof = _zkDefaultHonestProof();
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_VERSION] = _ZK_VERSION_0_22_0;
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_keys);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// Whatever the config holds, the root verifier receives the version the method accepts. The config has no
  /// version field, so neither a holder nor a submitter can choose the route a proof takes. `_release` builds any
  /// nonzero major, minor and patch as a canonical version word. `_identifierSeed` is bounded away from zero, since a
  /// zero identifier is refused before any call.
  function test_WhenTheMethodAcceptsAnyVersionAndTheConfigHoldsAnyValues(
    uint256 _release,
    uint256 _identifierSeed,
    string calldata _domain,
    string calldata _scope,
    uint256 _validity
  ) external {
    bytes32 _accepted = bytes32(bound(_release, 1, type(uint48).max) << 208);
    bytes32 _identifier = bytes32(bound(_identifierSeed, 1, type(uint256).max));
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_VERSION] = _accepted;
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_keys);
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    MethodZkPassportProofVerificationParams memory _params =
      _zkParams(_accepted, _data, _defaultCommittedInputs, _validity, _domain, _scope, false);
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _params,
      true,
      _identifier,
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );

    // it should call the root verifier once with the accepted version
    vm.expectCall(address(_rootMock), _zkRootCall(_params), 1);
    // it should accept the proof
    _zkAssertAccepted(
      _zkConfig(_identifier, _domain, _scope, _validity), _defaultDigest, _zkProof(_data, _defaultCommittedInputs)
    );
  }

  /// A proof calls none of the five snapshot addresses: the sub-verifier, the registry and the three outside roles.
  /// A watcher compares those words with zkPassport's live contracts. The method does not check them.
  function test_WhenAProofIsVerified() external {
    // it should call none of the snapshot addresses
    bytes memory _proof = _zkDefaultHonestProof();
    vm.expectCall(_SUB_VERIFIER, bytes(''), 0);
    vm.expectCall(_REGISTRY, bytes(''), 0);
    vm.expectCall(_ROOT_ADMIN, bytes(''), 0);
    vm.expectCall(_ROOT_GUARDIAN, bytes(''), 0);
    vm.expectCall(_SUB_VERIFIER_ADMIN, bytes(''), 0);
    _zkAssertAccepted(_zkDefaultConfig(), _defaultDigest, _proof);
  }

  /// A method deployed with a zero guardian word still verifies an honest proof.
  function test_WhenTheMethodIsDeployedWithAZeroGuardianWord() external {
    // it should accept an honest proof
    bytes memory _proof = _zkDefaultHonestProof();
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_ROOT_GUARDIAN] = bytes32(0);
    ZkPassportMethod _deployed = new ZkPassportMethod(_pauseHolder, _keyAdmin, _keys);
    assertEq(_deployed.verify(_zkDefaultConfig(), _defaultDigest, _proof), IPolicyMethod.verify.selector);
  }
}
