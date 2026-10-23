// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {VmSafe} from 'forge-std/Vm.sol';
import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {DeployIdentityMockLiveReads, DeployIdentityMockSubVerifier} from 'test/mocks/DeployIdentityMockLiveReads.sol';
import {DeployIdentityTestBase} from 'test/utils/DeployIdentityTestBase.sol';

/// @notice The second and third assertions without a chain: the comparison of a set of eight zkPassport words with
///         the live reads of the root verifier and the sub-verifier, here answered by mocks. The words are a reviewed
///         snapshot of zkPassport's route and roles, the method trusts that route between reviews, and the same
///         check runs before a Safe installs a new set with setTrustedKeys. Each test departs from a set every read
///         agrees with in one place: one word, or one read that fails or answers malformed. The fork suite proves the
///         same comparisons against the real contracts.
contract DeployIdentityCheckZkPassportKeysTest is DeployIdentityTestBase {
  function setUp() public override {
    super.setUp();
    _useLiveReadMocks();
  }

  /// checkZkPassportKeys passes when every live read agrees with the eight words: the root routes the accepted version
  /// to word three with verifier helper word four, names registry word five, and reports root admin and root guardian
  /// words six and seven, and the sub-verifier reports admin word eight.
  function test_WhenEveryLiveReadAgrees() external view {
    // it should pass
    _script.checkZkPassportKeys(_good8());
  }

  /// checkZkPassportKeys passes for a zero root guardian word when the live root reads a zero root guardian, the one
  /// role the root may leave empty.
  function test_WhenTheRootGuardianWordIsZeroAndTheRootHasNoRootGuardian() external {
    _inputs.rootGuardian = address(0);
    _rootMock.setAnswer(_GUARDIAN, DeployIdentityMockLiveReads.Mode.Value, address(0));
    // it should pass
    _script.checkZkPassportKeys(_good8());
  }

  /// checkZkPassportKeys reverts carrying the count, before any read, for a set of seven words, the eight without the
  /// sub-verifier admin. A proposed setTrustedKeys set of another length would be refused by the method anyway, and
  /// the check says so instead of reading out of bounds.
  function test_RevertWhen_TheSetHoldsSevenWords() external {
    bytes32[] memory _keys = _resized(7);
    // it should revert
    // it should carry the count
    // it should read nothing
    _expectBeforeAnyRead(_keys, abi.encodeWithSelector(IDeployIdentity.DeployIdentity_WordCount.selector, uint256(7)));
  }

  /// checkZkPassportKeys reverts carrying the count, before any read, for the eight words and a ninth, which a
  /// comparison of the first eight alone would pass.
  function test_RevertWhen_TheSetHoldsNineWords() external {
    bytes32[] memory _keys = _resized(9);
    // it should revert
    // it should carry the count
    // it should read nothing
    _expectBeforeAnyRead(_keys, abi.encodeWithSelector(IDeployIdentity.DeployIdentity_WordCount.selector, uint256(9)));
  }

  /// checkZkPassportKeys reverts carrying index one and the word, before any read, when the root verifier word has a
  /// bit set above its twenty address bytes. The word's low bytes name the agreeing mock root, so a check that
  /// truncated the word would read it and pass.
  function test_RevertWhen_TheRootVerifierWordIsNotClean() external {
    bytes32[] memory _keys = _good8();
    _keys[1] = bytes32(uint256(_keys[1]) | (uint256(1) << 200));
    // it should revert
    // it should carry the index and the word
    // it should read nothing
    _expectBeforeAnyRead(
      _keys, abi.encodeWithSelector(IDeployIdentity.DeployIdentity_WordNotClean.selector, uint256(1), _keys[1])
    );
  }

  /// checkZkPassportKeys reverts carrying index two and the word, before any read, when the sub-verifier word has a bit
  /// set above its twenty address bytes. The word's low bytes name the agreeing mock sub-verifier, so a check that
  /// truncated the word would compare it with the route and pass.
  function test_RevertWhen_TheSubVerifierWordIsNotClean() external {
    // it should revert
    // it should carry the index and the word
    // it should read nothing
    _expectDirtyWordRefused(2);
  }

  /// checkZkPassportKeys reverts carrying index three and the word, before any read, when the verifier helper word has
  /// a bit set above its twenty address bytes. The word's low bytes name the verifier helper the mock root returns, so
  /// a check that truncated the word would pass.
  function test_RevertWhen_TheVerifierHelperWordIsNotClean() external {
    // it should revert
    // it should carry the index and the word
    // it should read nothing
    _expectDirtyWordRefused(3);
  }

  /// checkZkPassportKeys reverts carrying index four and the word, before any read, when the registry word has a bit
  /// set above its twenty address bytes. The word's low bytes name the registry the mock root reports, so a check that
  /// truncated the word would pass.
  function test_RevertWhen_TheRegistryWordIsNotClean() external {
    // it should revert
    // it should carry the index and the word
    // it should read nothing
    _expectDirtyWordRefused(4);
  }

  /// checkZkPassportKeys reverts carrying index five and the word, before any read, when the root admin word has a bit
  /// set above its twenty address bytes. The word's low bytes name the root admin the mock root reports, so a check
  /// that truncated the word would pass.
  function test_RevertWhen_TheRootAdminWordIsNotClean() external {
    // it should revert
    // it should carry the index and the word
    // it should read nothing
    _expectDirtyWordRefused(5);
  }

  /// checkZkPassportKeys reverts carrying index six and the word, before any read, when the root guardian word has a
  /// bit set above its twenty address bytes. The word's low bytes name the root guardian the mock root reports, so a
  /// check that truncated the word would pass.
  function test_RevertWhen_TheRootGuardianWordIsNotClean() external {
    // it should revert
    // it should carry the index and the word
    // it should read nothing
    _expectDirtyWordRefused(6);
  }

  /// checkZkPassportKeys reverts carrying index seven and the word, before any read, when the sub-verifier admin word
  /// has a bit set above its twenty address bytes. The word's low bytes name the admin the mock sub-verifier reports,
  /// so a check that truncated the word would pass.
  function test_RevertWhen_TheSubVerifierAdminWordIsNotClean() external {
    // it should revert
    // it should carry the index and the word
    // it should read nothing
    _expectDirtyWordRefused(7);
  }

  /// checkZkPassportKeys reverts with the component mismatch named subVerifier, carrying word three and a zero live
  /// value, when word one names version 0.22.0, which the mock root routes nowhere. The sub-verifier is the first
  /// word a route read checks, so its read must ask for the version in the set: a check reading the route with the
  /// table's version 0.21.1 would find word three and fail later, on the verifier helper.
  function test_RevertWhen_TheVersionWordIsNotTheRoutedOne() external {
    bytes32[] memory _keys = _good8();
    _keys[0] = 0x0000001600000000000000000000000000000000000000000000000000000000;
    // it should revert
    // it should name subVerifier with the word and a zero live value
    _assertNamedMismatch(
      _reverting(_keys),
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'subVerifier',
      address(_subMock),
      address(0)
    );
  }

  /// checkZkPassportKeys passes when word one names version 0.22.0 and the mock root routes only 0.22.0 to the same
  /// sub-verifier and verifier helper. This is the check a Safe relies on before a setTrustedKeys moves to a new
  /// version, so the route reads must use the proposed version and never the table's 0.21.1.
  function test_WhenTheSetNamesAnotherVersionTheRootRoutes() external {
    bytes32 _proposed = 0x0000001600000000000000000000000000000000000000000000000000000000;
    _rootMock.setVersion(_proposed);
    bytes32[] memory _keys = _good8();
    _keys[0] = _proposed;
    // it should pass
    _script.checkZkPassportKeys(_keys);
  }

  /// checkZkPassportKeys reverts with the component mismatch named subVerifier, carrying the word and the live value,
  /// when word three names another sub-verifier than the one the live root routes the accepted version to. The other
  /// sub-verifier is a second mock reporting the same admin, so only the route disagrees.
  function test_RevertWhen_TheSubVerifierWordDiffers() external {
    DeployIdentityMockSubVerifier _otherSub = new DeployIdentityMockSubVerifier();
    _otherSub.setAnswer(_ADMIN, DeployIdentityMockLiveReads.Mode.Value, _inputs.subVerifierAdmin);
    bytes32[] memory _keys = _good8();
    address _replacement = address(_otherSub);
    _keys[2] = _word(_replacement);
    // it should revert
    // it should name subVerifier and carry the word and the live value
    _assertNamedMismatch(
      _reverting(_keys),
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'subVerifier',
      _replacement,
      address(_subMock)
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named verifierHelper, carrying the word and the live
  /// value, when word four names another verifier helper than the live root's for the accepted version.
  function test_RevertWhen_TheVerifierHelperWordDiffers() external {
    bytes32[] memory _keys = _good8();
    address _replacement = _freshAddress('unitOtherVerifierHelper', 0);
    _keys[3] = _word(_replacement);
    // it should revert
    // it should name verifierHelper and carry the word and the live value
    _assertNamedMismatch(
      _reverting(_keys),
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'verifierHelper',
      _replacement,
      _pins.verifierHelper
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named rootRegistry, carrying the word and the live value,
  /// when word five names another registry than the live root's.
  function test_RevertWhen_TheRegistryWordDiffers() external {
    bytes32[] memory _keys = _good8();
    address _replacement = _freshAddress('unitOtherRegistry', 0);
    _keys[4] = _word(_replacement);
    // it should revert
    // it should name rootRegistry and carry the word and the live value
    _assertNamedMismatch(
      _reverting(_keys),
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'rootRegistry',
      _replacement,
      _pins.rootRegistry
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootAdmin, carrying the word and the live value, when
  /// word six names another root admin than the live one.
  function test_RevertWhen_TheRootAdminWordDiffers() external {
    bytes32[] memory _keys = _good8();
    address _replacement = _freshAddress('unitOtherRootAdmin', 0);
    _keys[5] = _word(_replacement);
    // it should revert
    // it should name rootAdmin and carry the word and the live value
    _assertNamedMismatch(
      _reverting(_keys),
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootAdmin',
      _replacement,
      _inputs.rootAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootGuardian, carrying the word and the live value, when
  /// word seven names another root guardian than the live one.
  function test_RevertWhen_TheRootGuardianWordDiffers() external {
    bytes32[] memory _keys = _good8();
    address _replacement = _freshAddress('unitOtherRootGuardian', 0);
    _keys[6] = _word(_replacement);
    // it should revert
    // it should name rootGuardian and carry the word and the live value
    _assertNamedMismatch(
      _reverting(_keys),
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootGuardian',
      _replacement,
      _inputs.rootGuardian
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named subVerifierAdmin, carrying the word and the live value,
  /// when word eight names another sub-verifier admin than the live one.
  function test_RevertWhen_TheSubVerifierAdminWordDiffers() external {
    bytes32[] memory _keys = _good8();
    address _replacement = _freshAddress('unitOtherSubVerifierAdmin', 0);
    _keys[7] = _word(_replacement);
    // it should revert
    // it should name subVerifierAdmin and carry the word and the live value
    _assertNamedMismatch(
      _reverting(_keys),
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'subVerifierAdmin',
      _replacement,
      _inputs.subVerifierAdmin
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named subVerifier, carrying the expected word, when the
  /// read of the root's route to a sub-verifier for the accepted version reverts. A read that fails confirms nothing.
  function test_RevertWhen_TheSubVerifierReadReverts() external {
    // it should revert
    // it should name subVerifier and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GET_SUB_VERIFIER,
      DeployIdentityMockLiveReads.Mode.Revert,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'subVerifier',
      address(_subMock)
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named subVerifier, carrying the expected word, when the
  /// read of the root's route to a sub-verifier for the accepted version answers no bytes, the answer of an address
  /// without that function.
  function test_RevertWhen_TheSubVerifierReadAnswersNothing() external {
    // it should revert
    // it should name subVerifier and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GET_SUB_VERIFIER,
      DeployIdentityMockLiveReads.Mode.Empty,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'subVerifier',
      address(_subMock)
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named subVerifier, carrying the expected word, when the
  /// read of the root's route to a sub-verifier for the accepted version answers the expected address with a bit set
  /// above its twenty bytes. A word an address cannot hold is not that address, and truncating it would hide the
  /// difference.
  function test_RevertWhen_TheSubVerifierReadAnswersADirtyWord() external {
    // it should revert
    // it should name subVerifier and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GET_SUB_VERIFIER,
      DeployIdentityMockLiveReads.Mode.DirtyWord,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'subVerifier',
      address(_subMock)
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named subVerifier, carrying the expected word, when the
  /// read of the root's route to a sub-verifier for the accepted version answers the expected address followed by a
  /// second word. Only a clean one-word answer reads as an address.
  function test_RevertWhen_TheSubVerifierReadAnswersTwoWords() external {
    // it should revert
    // it should name subVerifier and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GET_SUB_VERIFIER,
      DeployIdentityMockLiveReads.Mode.TwoWords,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'subVerifier',
      address(_subMock)
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named verifierHelper, carrying the expected word, when the
  /// read of the root's verifier helper for the accepted version reverts. A read that fails confirms nothing.
  function test_RevertWhen_TheVerifierHelperReadReverts() external {
    // it should revert
    // it should name verifierHelper and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GET_HELPER,
      DeployIdentityMockLiveReads.Mode.Revert,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'verifierHelper',
      _pins.verifierHelper
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named verifierHelper, carrying the expected word, when the
  /// read of the root's verifier helper for the accepted version answers no bytes, the answer of an address without
  /// that function.
  function test_RevertWhen_TheVerifierHelperReadAnswersNothing() external {
    // it should revert
    // it should name verifierHelper and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GET_HELPER,
      DeployIdentityMockLiveReads.Mode.Empty,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'verifierHelper',
      _pins.verifierHelper
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named verifierHelper, carrying the expected word, when the
  /// read of the root's verifier helper for the accepted version answers the expected address with a bit set above its
  /// twenty bytes. A word an address cannot hold is not that address, and truncating it would hide the difference.
  function test_RevertWhen_TheVerifierHelperReadAnswersADirtyWord() external {
    // it should revert
    // it should name verifierHelper and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GET_HELPER,
      DeployIdentityMockLiveReads.Mode.DirtyWord,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'verifierHelper',
      _pins.verifierHelper
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named verifierHelper, carrying the expected word, when the
  /// read of the root's verifier helper for the accepted version answers the expected address followed by a second
  /// word. Only a clean one-word answer reads as an address.
  function test_RevertWhen_TheVerifierHelperReadAnswersTwoWords() external {
    // it should revert
    // it should name verifierHelper and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GET_HELPER,
      DeployIdentityMockLiveReads.Mode.TwoWords,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'verifierHelper',
      _pins.verifierHelper
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named rootRegistry, carrying the expected word, when the
  /// read of the root's registry reverts. A read that fails confirms nothing.
  function test_RevertWhen_TheRegistryReadReverts() external {
    // it should revert
    // it should name rootRegistry and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _ROOT_REGISTRY_READ,
      DeployIdentityMockLiveReads.Mode.Revert,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'rootRegistry',
      _pins.rootRegistry
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named rootRegistry, carrying the expected word, when the
  /// read of the root's registry answers no bytes, the answer of an address without that function.
  function test_RevertWhen_TheRegistryReadAnswersNothing() external {
    // it should revert
    // it should name rootRegistry and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _ROOT_REGISTRY_READ,
      DeployIdentityMockLiveReads.Mode.Empty,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'rootRegistry',
      _pins.rootRegistry
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named rootRegistry, carrying the expected word, when the
  /// read of the root's registry answers the expected address with a bit set above its twenty bytes. A word an address
  /// cannot hold is not that address, and truncating it would hide the difference.
  function test_RevertWhen_TheRegistryReadAnswersADirtyWord() external {
    // it should revert
    // it should name rootRegistry and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _ROOT_REGISTRY_READ,
      DeployIdentityMockLiveReads.Mode.DirtyWord,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'rootRegistry',
      _pins.rootRegistry
    );
  }

  /// checkZkPassportKeys reverts with the component mismatch named rootRegistry, carrying the expected word, when the
  /// read of the root's registry answers the expected address followed by a second word. Only a clean one-word answer
  /// reads as an address.
  function test_RevertWhen_TheRegistryReadAnswersTwoWords() external {
    // it should revert
    // it should name rootRegistry and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _ROOT_REGISTRY_READ,
      DeployIdentityMockLiveReads.Mode.TwoWords,
      IDeployIdentity.DeployIdentity_ComponentMismatch.selector,
      'rootRegistry',
      _pins.rootRegistry
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootAdmin, carrying the expected word, when the read of
  /// the root's admin reverts. A read that fails confirms nothing.
  function test_RevertWhen_TheRootAdminReadReverts() external {
    // it should revert
    // it should name rootAdmin and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _ADMIN,
      DeployIdentityMockLiveReads.Mode.Revert,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootAdmin',
      _inputs.rootAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootAdmin, carrying the expected word, when the read of
  /// the root's admin answers no bytes, the answer of an address without that function.
  function test_RevertWhen_TheRootAdminReadAnswersNothing() external {
    // it should revert
    // it should name rootAdmin and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _ADMIN,
      DeployIdentityMockLiveReads.Mode.Empty,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootAdmin',
      _inputs.rootAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootAdmin, carrying the expected word, when the read of
  /// the root's admin answers the expected address with a bit set above its twenty bytes. A word an address cannot
  /// hold is not that address, and truncating it would hide the difference.
  function test_RevertWhen_TheRootAdminReadAnswersADirtyWord() external {
    // it should revert
    // it should name rootAdmin and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _ADMIN,
      DeployIdentityMockLiveReads.Mode.DirtyWord,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootAdmin',
      _inputs.rootAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootAdmin, carrying the expected word, when the read of
  /// the root's admin answers the expected address followed by a second word. Only a clean one-word answer reads as an
  /// address.
  function test_RevertWhen_TheRootAdminReadAnswersTwoWords() external {
    // it should revert
    // it should name rootAdmin and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _ADMIN,
      DeployIdentityMockLiveReads.Mode.TwoWords,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootAdmin',
      _inputs.rootAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootGuardian, carrying the expected word, when the read
  /// of the root's root guardian reverts. A read that fails confirms nothing.
  function test_RevertWhen_TheRootGuardianReadReverts() external {
    // it should revert
    // it should name rootGuardian and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GUARDIAN,
      DeployIdentityMockLiveReads.Mode.Revert,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootGuardian',
      _inputs.rootGuardian
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootGuardian, carrying the expected word, when the read
  /// of the root's root guardian answers no bytes, the answer of an address without that function.
  function test_RevertWhen_TheRootGuardianReadAnswersNothing() external {
    // it should revert
    // it should name rootGuardian and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GUARDIAN,
      DeployIdentityMockLiveReads.Mode.Empty,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootGuardian',
      _inputs.rootGuardian
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootGuardian, carrying the expected word, when the read
  /// of the root's root guardian answers the expected address with a bit set above its twenty bytes. A word an address
  /// cannot hold is not that address, and truncating it would hide the difference.
  function test_RevertWhen_TheRootGuardianReadAnswersADirtyWord() external {
    // it should revert
    // it should name rootGuardian and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GUARDIAN,
      DeployIdentityMockLiveReads.Mode.DirtyWord,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootGuardian',
      _inputs.rootGuardian
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootGuardian, carrying the expected word, when the read
  /// of the root's root guardian answers the expected address followed by a second word. Only a clean one-word answer
  /// reads as an address.
  function test_RevertWhen_TheRootGuardianReadAnswersTwoWords() external {
    // it should revert
    // it should name rootGuardian and carry the expected word
    _expectBrokenRead(
      _rootMock,
      _GUARDIAN,
      DeployIdentityMockLiveReads.Mode.TwoWords,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'rootGuardian',
      _inputs.rootGuardian
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named subVerifierAdmin, carrying the expected word, when the
  /// read of the sub-verifier's admin reverts. A read that fails confirms nothing.
  function test_RevertWhen_TheSubVerifierAdminReadReverts() external {
    // it should revert
    // it should name subVerifierAdmin and carry the expected word
    _expectBrokenRead(
      _subMock,
      _ADMIN,
      DeployIdentityMockLiveReads.Mode.Revert,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'subVerifierAdmin',
      _inputs.subVerifierAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named subVerifierAdmin, carrying the expected word, when the
  /// read of the sub-verifier's admin answers no bytes, the answer of an address without that function.
  function test_RevertWhen_TheSubVerifierAdminReadAnswersNothing() external {
    // it should revert
    // it should name subVerifierAdmin and carry the expected word
    _expectBrokenRead(
      _subMock,
      _ADMIN,
      DeployIdentityMockLiveReads.Mode.Empty,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'subVerifierAdmin',
      _inputs.subVerifierAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named subVerifierAdmin, carrying the expected word, when the
  /// read of the sub-verifier's admin answers the expected address with a bit set above its twenty bytes. A word an
  /// address cannot hold is not that address, and truncating it would hide the difference.
  function test_RevertWhen_TheSubVerifierAdminReadAnswersADirtyWord() external {
    // it should revert
    // it should name subVerifierAdmin and carry the expected word
    _expectBrokenRead(
      _subMock,
      _ADMIN,
      DeployIdentityMockLiveReads.Mode.DirtyWord,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'subVerifierAdmin',
      _inputs.subVerifierAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named subVerifierAdmin, carrying the expected word, when the
  /// read of the sub-verifier's admin answers the expected address followed by a second word. Only a clean one-word
  /// answer reads as an address.
  function test_RevertWhen_TheSubVerifierAdminReadAnswersTwoWords() external {
    // it should revert
    // it should name subVerifierAdmin and carry the expected word
    _expectBrokenRead(
      _subMock,
      _ADMIN,
      DeployIdentityMockLiveReads.Mode.TwoWords,
      IDeployIdentity.DeployIdentity_RoleMismatch.selector,
      'subVerifierAdmin',
      _inputs.subVerifierAdmin
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootGuardian, carrying the zero word, when the root
  /// guardian word is zero and the root guardian read reverts. A failed read must not count as an answer of zero, or a
  /// root whose root guardian cannot be read would pass as one with no root guardian.
  function test_RevertWhen_TheRootGuardianWordIsZeroAndTheRootGuardianReadReverts() external {
    _inputs.rootGuardian = address(0);
    _rootMock.setAnswer(_GUARDIAN, DeployIdentityMockLiveReads.Mode.Revert, address(0));
    // it should revert
    // it should name rootGuardian and carry the zero word
    _assertNamedMismatchAnyActual(
      _reverting(_good8()), IDeployIdentity.DeployIdentity_RoleMismatch.selector, 'rootGuardian', address(0)
    );
  }

  /// checkZkPassportKeys reverts with the role mismatch named rootGuardian, carrying the zero word, when the root
  /// guardian word is zero and the root guardian read answers no bytes. A failed read must not count as an answer of
  /// zero, or a root whose root guardian cannot be read would pass as one with no root guardian.
  function test_RevertWhen_TheRootGuardianWordIsZeroAndTheRootGuardianReadAnswersNothing() external {
    _inputs.rootGuardian = address(0);
    _rootMock.setAnswer(_GUARDIAN, DeployIdentityMockLiveReads.Mode.Empty, address(0));
    // it should revert
    // it should name rootGuardian and carry the zero word
    _assertNamedMismatchAnyActual(
      _reverting(_good8()), IDeployIdentity.DeployIdentity_RoleMismatch.selector, 'rootGuardian', address(0)
    );
  }

  /// @notice The eight words of the table and inputs, which every configured read agrees with.
  function _good8() internal view returns (bytes32[] memory _keys) {
    _keys = _words(_pins, _inputs);
  }

  /// @notice The good set cut or extended to `_length` words, extended with copies of the last word.
  function _resized(uint256 _length) internal view returns (bytes32[] memory _keys) {
    bytes32[] memory _eight = _good8();
    _keys = new bytes32[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _keys[_i] = _eight[_i < _KEY_COUNT ? _i : _KEY_COUNT - 1];
    }
  }

  /// @notice Calls checkZkPassportKeys with `_keys`, requires it to revert, and returns the revert data.
  function _reverting(bytes32[] memory _keys) internal returns (bytes memory _reason) {
    try _script.checkZkPassportKeys(_keys) {
      fail('checkZkPassportKeys did not revert');
    } catch (bytes memory _caught) {
      _reason = _caught;
    }
  }

  /// @notice Requires checkZkPassportKeys to revert with exactly `_expected` without calling either mock.
  function _expectBeforeAnyRead(bytes32[] memory _keys, bytes memory _expected) internal {
    vm.startStateDiffRecording();
    bytes memory _reason = _reverting(_keys);
    VmSafe.AccountAccess[] memory _accesses = vm.stopAndReturnStateDiff();
    assertEq(_reason, _expected, 'revert data');
    for (uint256 _i; _i < _accesses.length; ++_i) {
      address _account = _accesses[_i].account;
      assertTrue(_account != address(_rootMock) && _account != address(_subMock), 'a live read before the check');
    }
  }

  /// @notice Sets a bit above the twenty address bytes of word `_index` of the good set, then requires
  ///         checkZkPassportKeys to revert with the dirty word error carrying that index and word, without calling
  ///         either mock.
  function _expectDirtyWordRefused(uint256 _index) internal {
    bytes32[] memory _keys = _good8();
    _keys[_index] = bytes32(uint256(_keys[_index]) | (uint256(1) << 200));
    _expectBeforeAnyRead(
      _keys, abi.encodeWithSelector(IDeployIdentity.DeployIdentity_WordNotClean.selector, _index, _keys[_index])
    );
  }

  /// @notice Makes the read `_selector` of `_mock` answer `_expected` in `_mode`, then requires the good set to
  ///         revert with `_error`, `_name` and `_expected`, whatever live value it reports.
  function _expectBrokenRead(
    DeployIdentityMockLiveReads _mock,
    bytes4 _selector,
    DeployIdentityMockLiveReads.Mode _mode,
    bytes4 _error,
    string memory _name,
    address _expected
  ) internal {
    _mock.setAnswer(_selector, _mode, _expected);
    _assertNamedMismatchAnyActual(_reverting(_good8()), _error, _name, _expected);
  }
}
