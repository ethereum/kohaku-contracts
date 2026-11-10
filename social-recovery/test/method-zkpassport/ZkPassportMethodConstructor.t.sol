// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IZkPassportMethod} from 'contracts/methods/zkpassport/IZkPassportMethod.sol';
import {ZkPassportMethod} from 'contracts/methods/zkpassport/ZkPassportMethod.sol';
import {MethodZkPassportFixture} from 'test/utils/MethodZkPassportFixture.sol';

/// @notice Tests the zkPassport method's constructor: the roles it sets and the initial key words it refuses. Who
///         may act in each role is tested with the roles base.
contract ZkPassportMethodConstructorTest is MethodZkPassportFixture {
  /// The constructor makes its first argument the pause holder and its second the key admin. It stores the eight
  /// words in the order given. Swapped roles would let the wrong party stop the method or change what it trusts.
  function test_WhenEveryArgumentIsValid() external {
    address _owner = makeAddr('otherPauseHolder');
    address _admin = makeAddr('otherKeyAdmin');
    bytes32[] memory _keys = _zkKeys(makeAddr('otherRoot'), makeAddr('otherVerifierHelper'));
    ZkPassportMethod _deployed = new ZkPassportMethod(_owner, _admin, _keys);

    (address _reportedAdmin,, bytes32[] memory _stored, address _reportedPauseHolder,) = _deployed.trustedParties();
    // it should make the initial owner the pause holder
    assertEq(_deployed.owner(), _owner, 'owner');
    assertEq(_reportedPauseHolder, _owner, 'pauseHolder');
    // it should make the initial admin the key admin
    assertEq(_reportedAdmin, _admin, 'admin');
    // it should store the eight initial words in order
    assertEq(_stored.length, _KEY_COUNT, 'length');
    for (uint256 _i; _i < _KEY_COUNT; ++_i) {
      assertEq(_stored[_i], _keys[_i], 'word');
    }
  }

  /// The root verifier in the initial list is the one every later list must keep. A list that keeps it is
  /// accepted, and a list naming the fixture's other router is refused with the fixed and the proposed words. The
  /// key admin can then never point the method at a router of its own.
  function test_WhenTheInitialListNamesARootVerifier() external {
    address _fixed = makeAddr('deployedRoot');
    ZkPassportMethod _deployed =
      new ZkPassportMethod(_pauseHolder, _keyAdmin, _zkKeys(_fixed, address(_verifierHelperMock)));

    // it should accept a later list that keeps that root verifier
    bytes32[] memory _kept = _zkKeys(_fixed, makeAddr('laterVerifierHelper'));
    vm.prank(_keyAdmin);
    _deployed.setTrustedKeys(_kept);
    (,, bytes32[] memory _stored,,) = _deployed.trustedParties();
    assertEq(_stored[_WORD_ROOT], _zkWord(_fixed), 'root verifier word');

    // it should refuse a later list naming another root verifier
    vm.prank(_keyAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        IZkPassportMethod.ZkPassportMethod_RootVerifierChanged.selector, _zkWord(_fixed), _zkWord(address(_rootMock))
      )
    );
    _deployed.setTrustedKeys(_zkKeys(address(_rootMock), address(_verifierHelperMock)));
  }

  /// Deploying with seven words reverts with the length error. The method reads each word at a fixed position. A
  /// short set would leave one of them unset.
  function test_RevertWhen_TheInitialKeysAreSeven() external {
    // it should revert
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_InvalidTrustedKeysLength.selector, uint256(7))
    );
    new ZkPassportMethod(_pauseHolder, _keyAdmin, _zkResized(7));
  }

  /// Deploying with nine words reverts with the length error. An extra word has no meaning in the layout.
  function test_RevertWhen_TheInitialKeysAreNine() external {
    // it should revert
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_InvalidTrustedKeysLength.selector, uint256(9))
    );
    new ZkPassportMethod(_pauseHolder, _keyAdmin, _zkResized(9));
  }

  /// Deploying with a zero in any word other than the guardian reverts and names the index. The method cannot be
  /// deployed with a blank version word, root verifier, verifier helper or declared party.
  function test_RevertWhen_AnyInitialWordButTheGuardianIsZero() external {
    // it should revert
    for (uint256 _i; _i < _KEY_COUNT; ++_i) {
      if (_i == _WORD_ROOT_GUARDIAN) continue;
      bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
      _keys[_i] = bytes32(0);
      vm.expectRevert(abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_ZeroTrustedKey.selector, _i));
      new ZkPassportMethod(_pauseHolder, _keyAdmin, _keys);
    }
  }

  /// Deploying with a zero guardian word succeeds and stores the zero. zkPassport's root may have no guardian.
  function test_WhenTheInitialGuardianWordIsZero() external {
    // it should deploy and store the zero word
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_ROOT_GUARDIAN] = bytes32(0);
    ZkPassportMethod _deployed = new ZkPassportMethod(_pauseHolder, _keyAdmin, _keys);
    (,, bytes32[] memory _stored,,) = _deployed.trustedParties();
    assertEq(_stored.length, _KEY_COUNT);
    assertEq(_stored[_WORD_ROOT_GUARDIAN], bytes32(0));
  }

  /// Deploying with a version word whose last twenty six bytes are not all zero reverts and names the word. A
  /// version word holds major, minor and patch in its first six bytes. A word with other bytes set names no release.
  function test_RevertWhen_TheInitialVersionWordIsNotCanonical() external {
    // it should revert
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_VERSION] = _zkDirtyVersion(_ZK_VERSION_0_21_0, 1);
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_VersionWordNotCanonical.selector, _keys[_WORD_VERSION])
    );
    new ZkPassportMethod(_pauseHolder, _keyAdmin, _keys);
  }

  /// A version word whose only set bit is in the padding is not zero. Deploying with it reverts with the version
  /// error, not the zero error.
  function test_RevertWhen_TheInitialVersionWordHasOnlyPaddingSet() external {
    // it should revert
    // it should carry the version error, not the zero error
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_VERSION] = bytes32(uint256(1));
    vm.expectRevert(
      abi.encodeWithSelector(IZkPassportMethod.ZkPassportMethod_VersionWordNotCanonical.selector, bytes32(uint256(1)))
    );
    new ZkPassportMethod(_pauseHolder, _keyAdmin, _keys);
  }

  /// Deploying with the largest address in every address word succeeds. The check on the upper twelve bytes never
  /// refuses a real address.
  function test_WhenEveryInitialAddressWordHoldsTheLargestAddress() external {
    // it should deploy and store every word
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    for (uint256 _i = _WORD_ROOT; _i < _KEY_COUNT; ++_i) {
      _keys[_i] = _zkWord(address(type(uint160).max));
    }
    ZkPassportMethod _deployed = new ZkPassportMethod(_pauseHolder, _keyAdmin, _keys);
    (,, bytes32[] memory _stored,,) = _deployed.trustedParties();
    for (uint256 _i; _i < _KEY_COUNT; ++_i) {
      assertEq(_stored[_i], _keys[_i], 'word');
    }
  }

  /// Deploying with release 65535.65535.65535 succeeds. The padding check starts at the seventh byte. It never
  /// reaches into the patch number.
  function test_WhenTheInitialVersionWordIsTheHighestRelease() external {
    // it should deploy and store the version word
    bytes32[] memory _keys = _zkKeys(address(_rootMock), address(_verifierHelperMock));
    _keys[_WORD_VERSION] = bytes32(uint256(type(uint48).max) << 208);
    ZkPassportMethod _deployed = new ZkPassportMethod(_pauseHolder, _keyAdmin, _keys);
    (,, bytes32[] memory _stored,,) = _deployed.trustedParties();
    assertEq(_stored[_WORD_VERSION], _keys[_WORD_VERSION]);
  }
}
