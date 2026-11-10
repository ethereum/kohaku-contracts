// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IZkPassportMethod} from 'contracts/methods/zkpassport/IZkPassportMethod.sol';
import {ZkPassportMethod} from 'contracts/methods/zkpassport/ZkPassportMethod.sol';
import {
  MethodZkPassportProofVerificationData,
  MethodZkPassportProofVerificationParams
} from 'test/mocks/MethodZkPassportMocks.sol';
import {MethodZkPassportFixture} from 'test/utils/MethodZkPassportFixture.sol';

/// @notice Fuzz tests of the zkPassport method's key rules, through the constructor and setTrustedKeys, and of
///         verify's checks against the mocks. Each test covers one side of one condition. Its inputs are bounded with
///         `bound` or built to stay on that side.
/// @dev A `_delta` is a nonzero value XORed into another value to build a different one. An `_upper` or `_padding`
///      seed sets the nonzero bytes the fixture adds to a word, and the fixture bounds it.
contract ZkPassportMethodFuzzTest is MethodZkPassportFixture {
  /*///////////////////////////////////////////////////////////////
                           CONSTRUCTOR
  ///////////////////////////////////////////////////////////////*/

  /// Deploying with fewer than eight words reverts with the length error for every such length. `_length` is
  /// bounded to zero through seven.
  function test_RevertWhen_TheInitialKeysAreFewerThanEight(uint256 _length) external {
    // it should revert
    _length = bound(_length, 0, _KEY_COUNT - 1);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_InvalidTrustedKeysLength.selector, _length)
    );
    new ZkPassportMethod(_pauseHolder, _keyAdmin, _zkResized(_length));
  }

  /// Deploying with more than eight words reverts with the length error for every such length. `_length` is
  /// bounded to nine through sixty four.
  function test_RevertWhen_TheInitialKeysAreMoreThanEight(uint256 _length) external {
    // it should revert
    _length = bound(_length, _KEY_COUNT + 1, 64);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_InvalidTrustedKeysLength.selector, _length)
    );
    new ZkPassportMethod(_pauseHolder, _keyAdmin, _zkResized(_length));
  }

  /// Deploying with an address word whose upper twelve bytes are not zero reverts and names the index and the word.
  /// Such a word does not hold exactly one address. Cutting it down would trust an address nobody wrote in full.
  /// `_index` is bounded to the seven address words.
  function test_RevertWhen_AnInitialAddressWordHasUpperBytesSet(uint256 _index, uint256 _upper) external {
    // it should revert
    _index = bound(_index, _WORD_ROOT, _KEY_COUNT - 1);
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_index] = _zkDirty(_keys[_index], _upper);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_AddressWordNotClean.selector, _index, _keys[_index])
    );
    new ZkPassportMethod(_pauseHolder, _keyAdmin, _keys);
  }

  /*///////////////////////////////////////////////////////////////
                         SET TRUSTED KEYS
  ///////////////////////////////////////////////////////////////*/

  /// When the key admin sets fewer than eight words, the call reverts with the length error. The stored words do not
  /// change. `_length` is bounded to zero through seven.
  function test_RevertWhen_TheKeyAdminSetsFewerThanEightWords(uint256 _length) external {
    // it should revert
    _length = bound(_length, 0, _KEY_COUNT - 1);
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_InvalidTrustedKeysLength.selector, _length)
    );
    _method.setTrustedKeys(_zkResized(_length));
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// When the key admin sets more than eight words, the call reverts with the length error. The stored words do not
  /// change. `_length` is bounded to nine through sixty four.
  function test_RevertWhen_TheKeyAdminSetsMoreThanEightWords(uint256 _length) external {
    // it should revert
    _length = bound(_length, _KEY_COUNT + 1, 64);
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_InvalidTrustedKeysLength.selector, _length)
    );
    _method.setTrustedKeys(_zkResized(_length));
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// When the key admin sets a zero in any word but the guardian and the fixed root verifier, the call reverts and
  /// names the index. The stored words do not change. A key change cannot blank the version word or the verifier
  /// helper. `_indexSeed` picks one of the six indexes 0, 2, 3, 4, 5 and 7: a zero root word also changes the fixed
  /// router, which the specification leaves unordered, and the guardian may be zero.
  function test_RevertWhen_TheKeyAdminSetsAZeroInAnyWordButTheGuardian(uint256 _indexSeed) external {
    // it should revert
    uint256 _index = bound(_indexSeed, 0, _KEY_COUNT - 3);
    if (_index > _WORD_VERSION) ++_index;
    if (_index == _WORD_ROOT_GUARDIAN) _index = _WORD_SUB_VERIFIER_ADMIN;
    bytes32[] memory _keys = _zkKeys(address(_rootMock), makeAddr('otherVerifierHelper'));
    _keys[_index] = bytes32(0);
    vm.prank(_keyAdmin);
    vm.expectRevert(abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_ZeroTrustedKey.selector, _index));
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// When the key admin sets an address word whose upper twelve bytes are not zero, the call reverts and names the
  /// index and the word. The stored words do not change. `_index` is bounded to the six address words after the
  /// root verifier, since a dirty root word also changes the fixed router, which the specification leaves unordered.
  function test_RevertWhen_TheKeyAdminSetsAnAddressWordWithUpperBytesSet(uint256 _index, uint256 _upper) external {
    // it should revert
    _index = bound(_index, _WORD_SUB_VERIFIER, _KEY_COUNT - 1);
    bytes32[] memory _keys = _zkKeys(address(_rootMock), makeAddr('otherVerifierHelper'));
    _keys[_index] = _zkDirty(_keys[_index], _upper);
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_AddressWordNotClean.selector, _index, _keys[_index])
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// The key admin can set any nonzero address in any address word after the root verifier, and the method stores
  /// it, while the root verifier word keeps the fixed router. The upper bytes check never refuses a word that holds
  /// exactly one address. `_index` is bounded to the six address words after the root verifier and `_account` to
  /// one through the largest address.
  function test_WhenTheKeyAdminSetsACleanAddressInAnyAddressWord(uint256 _index, uint256 _account) external {
    // it should store the word as given
    _index = bound(_index, _WORD_SUB_VERIFIER, _KEY_COUNT - 1);
    _account = bound(_account, 1, type(uint160).max);
    bytes32[] memory _keys = _zkKeys(address(_rootMock), makeAddr('otherVerifierHelper'));
    _keys[_index] = bytes32(_account);
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_keys);
    (,, bytes32[] memory _stored,,) = _method.trustedParties();
    assertEq(_stored[_index], _keys[_index]);
  }

  /// When the key admin sets a version word with any nonzero padding, the call reverts and names the word. The
  /// stored words do not change. The padding is added to release 0.21.0.
  function test_RevertWhen_TheKeyAdminSetsAVersionWordWithAnyNonzeroPadding(uint256 _padding) external {
    // it should revert
    bytes32[] memory _keys = _zkKeys(address(_rootMock), makeAddr('otherVerifierHelper'));
    _keys[_WORD_VERSION] = _zkDirtyVersion(_ZK_VERSION_0_21_0, _padding);
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_VersionWordNotCanonical.selector, _keys[_WORD_VERSION])
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// The key admin can set a canonical version word for any release, and the method stores it. The padding check
  /// never blocks a real upgrade. `_release` is bounded to one through the largest six-byte value. It is read as
  /// major, minor and patch, and put in the first six bytes with zeroes after.
  function test_WhenTheKeyAdminSetsACanonicalVersionWordForAnyRelease(uint256 _release) external {
    // it should store the word as given
    _release = bound(_release, 1, type(uint48).max);
    bytes32[] memory _keys = _zkKeys(address(_rootMock), makeAddr('otherVerifierHelper'));
    _keys[_WORD_VERSION] = bytes32(_release << 208);
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_keys);
    (,, bytes32[] memory _stored,,) = _method.trustedParties();
    assertEq(_stored[_WORD_VERSION], _keys[_WORD_VERSION]);
  }

  /// When the key admin proposes any other clean, nonzero root verifier with every other word valid, the call
  /// reverts with the fixed and the proposed words, and the stored words do not change. `_seed` builds the proposed
  /// router as a fresh address from keccak256 of a label and the seed, moved off zero and off the fixed router.
  function test_RevertWhen_TheKeyAdminProposesAnyOtherRootVerifier(uint256 _seed) external {
    // it should revert
    address _proposed = address(uint160(uint256(keccak256(abi.encode('proposedRootVerifier', _seed)))));
    if (_proposed == address(0)) _proposed = address(1);
    if (_proposed == address(_rootMock)) _proposed = address(uint160(_proposed) ^ 1);
    bytes32[] memory _keys = _zkKeys(_proposed, makeAddr('otherVerifierHelper'));
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        IZkPassportMethod.ZkPassportMethod_RootVerifierChanged.selector, _zkWord(address(_rootMock)), _zkWord(_proposed)
      )
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /*///////////////////////////////////////////////////////////////
                              VERIFY
  ///////////////////////////////////////////////////////////////*/

  /// The config's identifier, domain, scope and validity reach the root verifier unchanged. The proof is then
  /// checked under the rule the holder committed to. `_identifierSeed` is bounded away from zero, because a zero
  /// identifier is refused before any call.
  function test_WhenTheConfigCarriesAnyIdentifierDomainScopeAndValidity(
    uint256 _identifierSeed,
    string calldata _domain,
    string calldata _scope,
    uint256 _validity
  ) external {
    // it should pass them to the root verifier unchanged
    bytes32 _identifier = bytes32(bound(_identifierSeed, 1, type(uint256).max));
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    MethodZkPassportProofVerificationParams memory _params =
      _zkParams(_ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _validity, _domain, _scope, false);
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _params,
      true,
      _identifier,
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );
    vm.expectCall(address(_rootMock), _zkRootCall(_params), 1);
    _zkAssertAccepted(
      _zkConfig(_identifier, _domain, _scope, _validity), _defaultDigest, _zkProof(_data, _defaultCommittedInputs)
    );
  }

  /// When the root verifier returns any identifier other than the configured one, the proof is refused. One
  /// person's document cannot approve a recovery set up for another person. `_delta` is bounded to any nonzero
  /// 256-bit value and flipped into the configured identifier, so the difference can sit in any bit of the word.
  function test_WhenTheRootReturnsAnyIdentifierOtherThanTheConfiguredOne(uint256 _delta) external {
    // it should refuse the proof
    bytes32 _returned = bytes32(uint256(_defaultIdentifier) ^ bound(_delta, 1, type(uint256).max));
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_zkPublicInputs(8));
    _zkSetAnswers(
      _rootMock,
      _verifierHelperMock,
      _zkParams(
        _ZK_VERSION_0_21_0, _data, _defaultCommittedInputs, _defaultValidity, _defaultDomain, _defaultScope, false
      ),
      true,
      _returned,
      address(_verifierHelperMock),
      _zkRender(_defaultDigest)
    );
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// A nonzero nullifier type is refused for any number of public inputs. The nullifier type is the input at length
  /// minus three. Only the unsalted type, zero, ties the identifier to the document. `_length` is bounded to three
  /// through sixty four and `_typeSeed` to any nonzero 256-bit value.
  function test_WhenTheInputAtLengthMinusThreeIsAnyNonzeroValue(uint256 _length, uint256 _typeSeed) external {
    // it should refuse the proof
    _length = bound(_length, 3, 64);
    bytes32[] memory _inputs = _zkPublicInputs(_length);
    _inputs[_length - 3] = bytes32(bound(_typeSeed, 1, type(uint256).max));
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_inputs);
    _zkSetHonestAnswers(_data, _defaultDigest);
    _zkAssertRefused(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// A zero nullifier type, at length minus three, passes the check whatever the other inputs hold. `_length` is
  /// bounded to three through sixty four. `_salt` builds every other input as a nonzero hash.
  function test_WhenTheInputAtLengthMinusThreeIsZero(uint256 _length, uint256 _salt) external {
    // it should accept the proof
    _length = bound(_length, 3, 64);
    bytes32[] memory _inputs = new bytes32[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _inputs[_i] = bytes32(uint256(keccak256(abi.encode(_salt, _i))) | 1);
    }
    _inputs[_length - 3] = bytes32(0);
    MethodZkPassportProofVerificationData memory _data = _zkProofData(_inputs);
    _zkSetHonestAnswers(_data, _defaultDigest);
    _zkAssertAccepted(_zkDefaultConfig(), _defaultDigest, _zkProof(_data, _defaultCommittedInputs));
  }

  /// For any digest, custom data holding its lowercase rendering is accepted. A proof can bind any recovery digest.
  function test_WhenCustomDataIsTheLowercaseRenderingOfAnyDigest(bytes32 _digest) external {
    // it should accept the proof
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), _zkRender(_digest));
    _zkAssertAccepted(_zkDefaultConfig(), _digest, _proof);
  }

  /// Custom data rendering one digest is refused when verify is asked about another. A proof made for one recovery
  /// cannot approve another.
  function test_WhenCustomDataRendersADifferentDigest(bytes32 _digest, uint256 _delta) external {
    // it should refuse the proof
    bytes32 _other = bytes32(uint256(_digest) ^ bound(_delta, 1, type(uint256).max));
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), _zkRender(_digest));
    _zkAssertRefused(_zkDefaultConfig(), _other, _proof);
  }

  /// The uppercase rendering of a digest is refused. Only one text form counts, and the SDK writes that form.
  /// `_digestSeed` has its top four bits ORed with 1010. The first character is then a, b, e or f.
  function test_WhenCustomDataIsTheUppercaseRenderingOfADigestStartingWithALetter(bytes32 _digestSeed) external {
    // it should refuse the proof
    bytes32 _digest = bytes32(uint256(_digestSeed) | (uint256(0xa) << 252));
    bytes memory _proof = _zkDefaultHonestProof();
    _verifierHelperMock.setAnswer(keccak256(_defaultCommittedInputs), _zkRenderUpper(_digest));
    _zkAssertRefused(_zkDefaultConfig(), _digest, _proof);
  }

  /// The five snapshot words name zkPassport's sub-verifier, registry and three outside roles for a watcher. The
  /// method does not check them, and an honest proof is accepted whatever they hold. Each seed is bounded to a
  /// nonzero address. The guardian's seed may also be zero.
  function test_WhenTheSnapshotWordsHoldAnyValues(
    uint256 _subVerifier,
    uint256 _registry,
    uint256 _rootAdmin,
    uint256 _rootGuardian,
    uint256 _subVerifierAdmin
  ) external {
    // it should accept the proof
    bytes memory _proof = _zkDefaultHonestProof();
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_SUB_VERIFIER] = bytes32(bound(_subVerifier, 1, type(uint160).max));
    _keys[_WORD_REGISTRY] = bytes32(bound(_registry, 1, type(uint160).max));
    _keys[_WORD_ROOT_ADMIN] = bytes32(bound(_rootAdmin, 1, type(uint160).max));
    _keys[_WORD_ROOT_GUARDIAN] = bytes32(bound(_rootGuardian, 0, type(uint160).max));
    _keys[_WORD_SUB_VERIFIER_ADMIN] = bytes32(bound(_subVerifierAdmin, 1, type(uint160).max));
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_keys);
    _zkAssertAccepted(_zkDefaultConfig(), _defaultDigest, _proof);
  }
}
