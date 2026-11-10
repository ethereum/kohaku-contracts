// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyMethodAdmin} from 'interfaces/IPolicyMethodAdmin.sol';
import {IZkPassportMethod} from 'contracts/methods/zkpassport/IZkPassportMethod.sol';
import {MethodZkPassportRootVerifierMock} from 'test/mocks/MethodZkPassportMocks.sol';
import {MethodZkPassportFixture} from 'test/utils/MethodZkPassportFixture.sol';

/// @notice Tests the zkPassport method's key rules when the key admin replaces the eight words. Who may call
///         setTrustedKeys is tested with the roles base.
contract ZkPassportMethodSetTrustedKeysTest is MethodZkPassportFixture {
  /// The key admin keeps the root verifier and replaces every other word at once: the version, the helper pin and
  /// the five snapshots. The method emits an event with the previous and the new words, so a watcher can alert
  /// holders as soon as what the method trusts changes, and the root verifier still reads as the second word.
  function test_WhenTheKeyAdminSetsEightValidWords() external {
    bytes32[] memory _previous = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    bytes32[] memory _next = _zkKeys(address(_rootMock), makeAddr('nextVerifierHelper'));
    _next[_WORD_VERSION] = 0x0000001600000000000000000000000000000000000000000000000000000000;
    _next[_WORD_SUB_VERIFIER] = _zkWord(makeAddr('nextSubVerifier'));
    _next[_WORD_REGISTRY] = _zkWord(makeAddr('nextRegistry'));
    _next[_WORD_ROOT_ADMIN] = _zkWord(makeAddr('nextRootAdmin'));
    _next[_WORD_ROOT_GUARDIAN] = bytes32(0);
    _next[_WORD_SUB_VERIFIER_ADMIN] = _zkWord(makeAddr('nextSubVerifierAdmin'));

    // it should emit TrustedKeysUpdated with the previous and the new words
    vm.expectEmit(address(_method));
    emit IPolicyMethodAdmin.TrustedKeysUpdated(_previous, _next);
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_next);

    // it should store the eight new words in order
    (,, bytes32[] memory _stored,,) = _method.trustedParties();
    assertEq(_stored.length, _KEY_COUNT);
    for (uint256 _i; _i < _KEY_COUNT; ++_i) {
      assertEq(_stored[_i], _next[_i], 'word');
    }
    // it should still report the fixed root verifier as the second word
    assertEq(_stored[_WORD_ROOT], _zkWord(address(_rootMock)), 'root verifier word');
  }

  /// The key admin proposes eight words that are valid in every other way but name another root verifier, a
  /// contract of its own. The call reverts with the fixed and the proposed words and nothing changes. A key admin
  /// that could swap the router could answer valid for any identifier and forge every credential of this method.
  function test_RevertWhen_TheKeyAdminProposesAnotherRootVerifier() external {
    address _own = address(new MethodZkPassportRootVerifierMock());
    bytes32[] memory _keys = _zkKeys(_own, address(_verifierHelperMock));
    // it should revert
    // it should carry the fixed and the proposed words
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        IZkPassportMethod.ZkPassportMethod_RootVerifierChanged.selector, _zkWord(address(_rootMock)), _zkWord(_own)
      )
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// A root verifier word that keeps the fixed address but sets bits above it breaks two rules at once. The call is
  /// refused and nothing changes. Which of the two errors it carries is left unasserted.
  function test_RevertWhen_TheKeyAdminSetsADirtyRootVerifierWord() external {
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_ROOT] = _zkDirty(_keys[_WORD_ROOT], 1);
    // it should revert
    vm.prank(_keyAdmin);
    vm.expectRevert();
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// A zero root verifier word both differs from the fixed router and is a zero word. The call is refused and
  /// nothing changes. Which of the two errors it carries is left unasserted.
  function test_RevertWhen_TheKeyAdminSetsAZeroRootVerifierWord() external {
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_ROOT] = bytes32(0);
    // it should revert
    vm.prank(_keyAdmin);
    vm.expectRevert();
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// The key admin may set a zero guardian word, and the method stores it. zkPassport may drop its root guardian.
  function test_WhenTheKeyAdminSetsAZeroGuardianWord() external {
    // it should store the zero word
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_ROOT_GUARDIAN] = bytes32(0);
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_keys);
    (,, bytes32[] memory _stored,,) = _method.trustedParties();
    assertEq(_stored[_WORD_ROOT_GUARDIAN], bytes32(0));
  }

  /// A guardian word holding the zero address with nonzero upper bytes reverts with the address word error. The
  /// guardian word may be zero, but its upper twelve bytes must be zero too.
  function test_RevertWhen_TheKeyAdminSetsAGuardianWordWithOnlyUpperBytesSet() external {
    bytes32[] memory _keys = _zkKeys(address(_rootMock), makeAddr('otherVerifierHelper'));
    _keys[_WORD_ROOT_GUARDIAN] = _zkDirty(bytes32(0), 1);
    // it should revert
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        IZkPassportMethod.ZkPassportMethod_AddressWordNotClean.selector, _WORD_ROOT_GUARDIAN, _keys[_WORD_ROOT_GUARDIAN]
      )
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// Seven words that also include an address word with upper bytes set revert with the length error. The method
  /// checks the length before any word.
  function test_RevertWhen_TheKeyAdminSetsSevenWordsWithADirtyAddressWord() external {
    bytes32[] memory _keys = _zkResized(7);
    _keys[_WORD_ROOT] = _zkDirty(_keys[_WORD_ROOT], 1);
    // it should revert
    // it should carry the length error
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_InvalidTrustedKeysLength.selector, uint256(7))
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// A version word with every padding bit set reverts and names the word. A key change cannot make the method
  /// demand a version no proof can carry.
  function test_RevertWhen_TheKeyAdminSetsANonCanonicalVersionWord() external {
    bytes32[] memory _keys = _zkKeys(address(_rootMock), makeAddr('otherVerifierHelper'));
    _keys[_WORD_VERSION] = _zkDirtyVersion(_ZK_VERSION_0_21_0, type(uint208).max);
    // it should revert
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_VersionWordNotCanonical.selector, _keys[_WORD_VERSION])
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// A version word whose only padding bit sits in byte 6, the first byte after major, minor and patch, reverts
  /// with the version word error. The canonical check must cover every padding byte, starting right after the patch.
  function test_RevertWhen_TheKeyAdminSetsAVersionWordWithPaddingOnlyInTheFirstPaddingByte() external {
    bytes32[] memory _keys = _zkKeys(address(_rootMock), makeAddr('otherVerifierHelper'));
    _keys[_WORD_VERSION] = _ZK_VERSION_0_21_0 | bytes32(uint256(1) << 200);
    // it should revert
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_VersionWordNotCanonical.selector, _keys[_WORD_VERSION])
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }

  /// Seven words whose version word has padding bits set revert with the length error. The method checks the length
  /// before any word.
  function test_RevertWhen_TheKeyAdminSetsSevenWordsWithANonCanonicalVersionWord() external {
    bytes32[] memory _keys = _zkResized(7);
    _keys[_WORD_VERSION] = _zkDirtyVersion(_keys[_WORD_VERSION], 1);
    // it should revert
    // it should carry the length error
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_InvalidTrustedKeysLength.selector, uint256(7))
    );
    _method.setTrustedKeys(_keys);
    // it should keep the previous words
    _zkAssertKeysUnchanged();
  }
}
