// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyManager} from 'interfaces/IPolicyManager.sol';

import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {PolicyMethodRoles} from 'contracts/methods/roles/PolicyMethodRoles.sol';

import {IZkPassportRootVerifier} from 'contracts/methods/zkpassport/IZkPassportRootVerifier.sol';
import {IZkPassportVerifierHelper} from 'contracts/methods/zkpassport/IZkPassportVerifierHelper.sol';
import {IZkPassportMethod} from 'contracts/methods/zkpassport/IZkPassportMethod.sol';

import {IntegrationBase} from 'test/integration/base/IntegrationBase.sol';
import {LocalChain} from 'test/integration/base/LocalDeploy.sol';
import {LocalIdentityRoles, LocalZkPassportRootVerifier} from 'test/integration/base/LocalWorld.sol';

/// @notice A root verifier a compromised key admin deploys and tries to name in the zkPassport trusted keys: it
///         accepts every proof and answers the identifier its owner chose, through the verifier helper the method
///         already trusts.
/// @dev It stands for the forged verifier the trade-off is about, so it replaces nothing real.
contract RootVerifierTheKeyAdminControls {
  /// @notice The identifier every proof is answered with.
  bytes32 public immutable FORGED_IDENTIFIER;
  /// @notice The verifier helper returned with every answer.
  IZkPassportVerifierHelper public immutable VERIFIER_HELPER;

  constructor(bytes32 _forgedIdentifier, IZkPassportVerifierHelper _verifierHelper) {
    FORGED_IDENTIFIER = _forgedIdentifier;
    VERIFIER_HELPER = _verifierHelper;
  }

  /// @notice Accepts any proof as the chosen identifier's.
  function verify(IZkPassportRootVerifier.ProofVerificationParams calldata)
    external
    view
    returns (bool _valid, bytes32 _uniqueIdentifier, IZkPassportVerifierHelper _helper)
  {
    (_valid, _uniqueIdentifier, _helper) = (true, FORGED_IDENTIFIER, VERIFIER_HELPER);
  }
}

/// @notice The issuer behind an identity method has just moved on, so fresh proofs stop verifying until the key admin,
///         the deployment's Safe, follows. The holder's rule is any 2 of Ben's wallet and an identity guardian. The key
///         admin sets the new trusted keys, and the holder's request opens. The story is told once; each kind below
///         says which identity method moved and how.
abstract contract IdentityMethodKeyRotation is IntegrationBase {
  /// @notice Local only: its rule names an identity credential, which no story can prove on a fork.
  function _runsOnForks() internal pure override returns (bool _runs) {
    _runs = false;
  }

  /// @notice The holder's account.
  address internal _account;
  /// @notice The holder's rule, as the backup holds it.
  Rule internal _holderRule;

  function setUp() public virtual override {
    super.setUp();
    _account = _openAccount(_originalKey.addr);
    Rule memory _r = _rule(
      _account, 5 days, false, _thresholds(2), _sizes(2), _credentials(_walletGuardian(_ben), _identityCredential())
    );
    _keep(_holderRule, _r);
    _setUpRecovery(_account, _originalKey, _r);
  }

  /*///////////////////////////////////////////////////////////////
                         WHAT EACH KIND SAYS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The identity method that moved.
  function _identityMethod() internal view virtual returns (PolicyMethodRoles _method);

  /// @notice The identity guardian's credential in the holder's rule.
  function _identityCredential() internal virtual returns (Credential memory _credential);

  /// @notice The issuer moves on outside the chain, and the guardian's fresh proofs follow it.
  function _issuerRotates() internal virtual;

  /// @notice The trusted keys that follow the issuer's move.
  function _keysAfterTheRotation() internal view virtual returns (bytes32[] memory _keys);

  /// @notice What the identity method's next release does to the recovered holder's credential.
  function _afterTheRecovery() internal virtual;

  /*///////////////////////////////////////////////////////////////
                              THE WALK
  ///////////////////////////////////////////////////////////////*/

  /// @notice A fresh proof fails until the key admin sets the new trusted keys, then the guardian's fresh proof
  ///         verifies, the holder's request opens and the recovery completes. Keeping the keys current is what keeps an
  ///         identity credential usable.
  function test_WhenTheKeyAdminRotatesTheIssuerKey() external {
    Rule memory _r = _holderRule;
    // The issuer rotates, and the guardian's fresh proof follows the new issuer.
    _issuerRotates();

    // The holder sends a request whose identity proof follows the new issuer. It fails.
    IPolicyManager.AttemptRequest memory _before = _approversApprove(_r);
    vm.prank(_relayer);
    vm.expectRevert(_proofRejected(1, address(_identityMethod())));
    _manager.startAttempt(_before);

    // The key admin sends setTrustedKeys with the keys that follow the rotation.
    bytes32[] memory _keys = _keysAfterTheRotation();
    PolicyMethodRoles _method = _identityMethod();
    vm.prank(_identitySafe);
    _method.setTrustedKeys(_keys);

    // The guardian proves over the digest again, and the holder's request opens.
    IPolicyManager.AttemptRequest memory _after = _approversApprove(_r);
    _submits(_relayer, _after);
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Waiting), 'the request opened');

    // The wait passes, and the handover hands the account to the new key.
    skip(5 days);
    _executes(_executor, _account, _after.payload);
    _assertKeyControls(_account, _newKey, 'the new key');

    // At the method's next release, what the kind says happens to the credential.
    _afterTheRecovery();
  }

  /*///////////////////////////////////////////////////////////////
                              UTILITIES
  ///////////////////////////////////////////////////////////////*/

  /// @notice Ben signs place 0 and the identity guardian proves place 1 over a handover from the lost key to the new
  ///         key.
  function _approversApprove(Rule memory _r) internal view returns (IPolicyManager.AttemptRequest memory _req) {
    _req = _request(
      _account, _r, _handover(_newKey.addr, _originalKey.addr), _noPayment(), uint48(block.timestamp + 24 hours)
    );
    _signApproval(_req, _r, 0);
    _signApproval(_req, _r, 1);
  }
}

/// @notice The Aadhaar issuer rotated its signing key, so the guardian's fresh QR is signed under a new key hash. This
///         kind also carries the case where the story must hold even after the rotation, and the trade-offs the kit
///         accepts.
contract IdentityMethodKeyRotationOfTheAadhaarIssuerKey is IdentityMethodKeyRotation {
  /// @notice The hash of the issuer's new signing key.
  bytes32 internal constant _NEW_ISSUER_KEY = keccak256('UIDAI signing key, local issue 2');
  /// @notice The guardian's Aadhaar identity, seed and freshness window.
  uint256 internal constant _NULLIFIER = uint256(keccak256('Aadhaar guardian identity'));
  uint256 internal constant _SEED = 4242;
  uint256 internal constant _WINDOW = 3 days;

  function _identityMethod() internal view override returns (PolicyMethodRoles _method) {
    _method = PolicyMethodRoles(address(_aadhaarMethod));
  }

  function _identityCredential() internal override returns (Credential memory _credential) {
    _credential = _aadhaarGuardian(_NULLIFIER, _SEED, _WINDOW);
  }

  function _issuerRotates() internal override {
    // The issuer signs with its new key, and the guardian downloads a fresh QR signed under it.
    _downloadQr(_holderRule.places[1], _NEW_ISSUER_KEY, block.timestamp);
  }

  function _keysAfterTheRotation() internal pure override returns (bytes32[] memory _keys) {
    _keys = new bytes32[](1);
    _keys[0] = _NEW_ISSUER_KEY;
  }

  function _afterTheRecovery() internal override {
    // A month later the guardian downloads another QR under the new key, and a request moving the account to the second
    // new key opens: the credential keeps working once the key admin has followed.
    skip(30 days);
    Rule memory _r = _holderRule;
    _downloadQr(_r.places[1], _NEW_ISSUER_KEY, block.timestamp);
    IPolicyManager.AttemptRequest memory _req = _request(
      _account, _r, _handover(_secondNewKey.addr, _newKey.addr), _noPayment(), uint48(block.timestamp + 24 hours)
    );
    _signApproval(_req, _r, 0);
    _signApproval(_req, _r, 1);
    _submits(_relayer, _req);
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Waiting), 'the next request opened');
  }

  /*///////////////////////////////////////////////////////////////
                              EVEN IF
  ///////////////////////////////////////////////////////////////*/

  /// @notice An attempt accepted before the rotation still executes after it, although the same guardian's old proof no
  ///         longer counts for anything new. An accepted attempt is never judged again.
  function test_WhenAnAcceptedAttemptOutlivesTheRotation() external {
    Rule memory _r = _holderRule;
    // Ben and the identity guardian, with a QR under the old key, open the attempt.
    IPolicyManager.AttemptRequest memory _req = _approversApprove(_r);
    _submits(_relayer, _req);

    // The issuer rotates and the key admin follows.
    bytes32[] memory _keys = _keysAfterTheRotation();
    vm.prank(_identitySafe);
    _aadhaarMethod.setTrustedKeys(_keys);

    // Ben and the identity guardian, with the same old QR, sign a cancel, and it fails at the guardian's place.
    IPolicyManager.CancelRequest memory _cancel = _cancelRequest(_account, _r, 1, uint48(block.timestamp + 24 hours));
    _signCancel(_cancel, _r, 0);
    _signCancel(_cancel, _r, 1);
    vm.prank(_relayer);
    vm.expectRevert(_proofRejected(1, address(_aadhaarMethod)));
    _manager.cancelByProofs(_cancel);

    // The wait passes, and the attempt accepted before the rotation hands the account to the new key.
    skip(5 days);
    _executes(_executor, _account, _req.payload);
    _assertKeyControls(_account, _newKey, 'the new key');
  }

  /*///////////////////////////////////////////////////////////////
                             TRADE-OFFS
  ///////////////////////////////////////////////////////////////*/

  /// @notice A compromised key admin sets a key it controls and signs a QR for any identity. Raj, whose rule rests on
  ///         his Aadhaar guardian alone, sees his own recovery ended by a forged cancel and loses the account to a
  ///         forged approval.
  function test_WhenTheKeyAdminForgesAProof() external {
    // Raj set up recovery with his Aadhaar guardian alone, and lost his key.
    Person memory _raj = _person('Raj key');
    Person memory _rajNewKey = _person('Raj new key');
    address _rajAccount = _openAccount(_raj.addr);
    Credential memory _rajGuardian = _aadhaarGuardian(uint256(keccak256('Raj Aadhaar guardian')), _SEED, _WINDOW);
    Rule memory _rajRule = _rule(_rajAccount, 5 days, false, _thresholds(1), _sizes(1), _credentials(_rajGuardian));
    _setUpRecovery(_rajAccount, _raj, _rajRule);

    // Raj's guardian proves a handover to Raj's new key, and attempt 1 opens.
    IPolicyManager.AttemptRequest memory _honest = _request(
      _rajAccount, _rajRule, _handover(_rajNewKey.addr, _raj.addr), _noPayment(), uint48(block.timestamp + 24 hours)
    );
    _signApproval(_honest, _rajRule, 0);
    _submits(_relayer, _honest);

    // The compromised key admin sets a key the attacker controls.
    bytes32 _attackerKey = keccak256('attacker signing key');
    bytes32[] memory _keys = new bytes32[](1);
    _keys[0] = _attackerKey;
    vm.prank(_identitySafe);
    _aadhaarMethod.setTrustedKeys(_keys);

    // The attacker signs a QR for the guardian's identity under that key, and with it cancels attempt 1.
    _downloadQr(_rajRule.places[0], _attackerKey, block.timestamp);
    IPolicyManager.CancelRequest memory _cancel =
      _cancelRequest(_rajAccount, _rajRule, 1, uint48(block.timestamp + 24 hours));
    _signCancel(_cancel, _rajRule, 0);
    _submitsCancel(_attacker.addr, _cancel);

    // With the same forged QR the attacker approves a handover to their own key, and attempt 2 opens.
    bytes memory _payload = _handover(_attacker.addr, _raj.addr);
    IPolicyManager.AttemptRequest memory _forged =
      _request(_rajAccount, _rajRule, _payload, _noPayment(), uint48(block.timestamp + 24 hours));
    _signApproval(_forged, _rajRule, 0);
    _submits(_attacker.addr, _forged);

    // The wait passes, and the attacker takes Raj's account.
    skip(5 days);
    _executes(_attacker.addr, _rajAccount, _payload);
    _assertKeyControls(_rajAccount, _attacker, 'the attacker');
    assertEq(_privilegeOf(_rajAccount, _rajNewKey.addr), bytes32(0), 'Raj new key holds nothing');
  }

  /// @notice The issuer rotates while a hostile attempt waits. Until the key admin follows, the guardian's fresh QR
  ///         fails and the old one has gone stale, so the cancel that leans on the Aadhaar guardian is refused and the
  ///         hostile attempt executes.
  function test_WhenARotationRemovesTheGuardiansCancel() external {
    // Nina's rule is any 2 of Ana, Ben, her Aadhaar guardian and Carla. The attacker stole Ana's and Ben's keys.
    Person memory _nina = _person('Nina key');
    address _ninaAccount = _openAccount(_nina.addr);
    Credential memory _ninaGuardian = _aadhaarGuardian(uint256(keccak256('Nina Aadhaar guardian')), _SEED, 1 days);
    Rule memory _ninaRule = _rule(
      _ninaAccount,
      5 days,
      false,
      _thresholds(2),
      _sizes(4),
      _credentials(_walletGuardian(_ana), _walletGuardian(_ben), _ninaGuardian, _walletGuardian(_carla))
    );
    _setUpRecovery(_ninaAccount, _nina, _ninaRule);

    // The attacker signs places 0 and 1 and opens a handover to their own key.
    bytes memory _payload = _handover(_attacker.addr, _nina.addr);
    IPolicyManager.AttemptRequest memory _hostile =
      _request(_ninaAccount, _ninaRule, _payload, _noPayment(), uint48(block.timestamp + 24 hours));
    _signApproval(_hostile, _ninaRule, 0);
    _signApproval(_hostile, _ninaRule, 1);
    _submits(_attacker.addr, _hostile);

    // Two days in, the issuer has rotated its key and the key admin has not followed yet.
    skip(2 days);

    // The guardian's QR from the start of the wait is stale, and the cancel by the guardian and Carla fails.
    _downloadQr(_ninaRule.places[2], LocalChain.AADHAAR_ISSUER_KEY, block.timestamp - 2 days);
    IPolicyManager.CancelRequest memory _stale =
      _cancelRequest(_ninaAccount, _ninaRule, 1, uint48(block.timestamp + 24 hours));
    _signCancel(_stale, _ninaRule, 2);
    _signCancel(_stale, _ninaRule, 3);
    vm.prank(_relayer);
    vm.expectRevert(_proofRejected(2, address(_aadhaarMethod)));
    _manager.cancelByProofs(_stale);

    // The guardian downloads a fresh QR, signed under the new key, and the same cancel fails again.
    _downloadQr(_ninaRule.places[2], _NEW_ISSUER_KEY, block.timestamp);
    IPolicyManager.CancelRequest memory _fresh =
      _cancelRequest(_ninaAccount, _ninaRule, 1, uint48(block.timestamp + 24 hours));
    _signCancel(_fresh, _ninaRule, 2);
    _signCancel(_fresh, _ninaRule, 3);
    vm.prank(_relayer);
    vm.expectRevert(_proofRejected(2, address(_aadhaarMethod)));
    _manager.cancelByProofs(_fresh);

    // The wait ends, and the attacker takes Nina's account.
    skip(3 days);
    _executes(_attacker.addr, _ninaAccount, _payload);
    _assertKeyControls(_ninaAccount, _attacker, 'the attacker');
    _assertKeyLocked(_ninaAccount, _nina);
  }
}

/// @notice zkPassport shipped a new release and retired the old one's route at its root verifier. The release keeps the
///         identifier derivation, so the passport committed in the rule keeps matching once the accepted version moves.
///         A later release that changes the derivation strands the committed passport once the version moves again.
contract IdentityMethodKeyRotationOfTheZkPassportVersion is IdentityMethodKeyRotation {
  /// @notice zkPassport 0.22.0 and 0.23.0 as version words.
  bytes32 internal constant _NEW_VERSION = 0x0000001600000000000000000000000000000000000000000000000000000000;
  bytes32 internal constant _LATER_VERSION = 0x0000001700000000000000000000000000000000000000000000000000000000;

  function _identityMethod() internal view override returns (PolicyMethodRoles _method) {
    _method = PolicyMethodRoles(address(_zkPassportMethod));
  }

  function _identityCredential() internal override returns (Credential memory _credential) {
    _credential = _passport(keccak256('Maya passport chip'));
  }

  function _issuerRotates() internal override {
    // zkPassport routes its new release with the same derivation and retires the old release's route.
    _zkPassportShips(LocalChain.ZKPASSPORT_VERSION, _NEW_VERSION, LocalChain.ZKPASSPORT_DERIVATION);
  }

  function _keysAfterTheRotation() internal view override returns (bytes32[] memory _keys) {
    (,, _keys,,) = _zkPassportMethod.trustedParties();
    _keys[0] = _NEW_VERSION;
  }

  function _afterTheRecovery() internal override {
    // zkPassport ships a later release that changes the identifier derivation and retires the current route.
    _zkPassportShips(_NEW_VERSION, _LATER_VERSION, keccak256('zkPassport identifier derivation v2'));

    // The key admin moves the accepted version.
    (,, bytes32[] memory _keys,,) = _zkPassportMethod.trustedParties();
    _keys[0] = _LATER_VERSION;
    vm.prank(_identitySafe);
    _zkPassportMethod.setTrustedKeys(_keys);

    // Ben and the same passport approve a move to a second new key, and the request fails at the passport's place.
    Rule memory _r = _holderRule;
    IPolicyManager.AttemptRequest memory _req = _request(
      _account, _r, _handover(_secondNewKey.addr, _newKey.addr), _noPayment(), uint48(block.timestamp + 24 hours)
    );
    _signApproval(_req, _r, 0);
    _signApproval(_req, _r, 1);
    vm.prank(_relayer);
    vm.expectRevert(_proofRejected(1, address(_zkPassportMethod)));
    _manager.startAttempt(_req);
  }

  /*///////////////////////////////////////////////////////////////
                             TRADE-OFFS
  ///////////////////////////////////////////////////////////////*/

  /// @notice A compromised key admin tries to name a root verifier it controls in the trusted keys. The method refuses
  ///         the list with the fixed and the proposed router, so a proof made without the passport stays refused:
  ///         Raj, whose rule rests on his passport alone, keeps his recovery through the admin's attempt and gets his
  ///         account back.
  function test_WhenTheKeyAdminTriesToRouteProofsToARootVerifierItControls() external {
    // Raj set up recovery with his passport alone, and lost his key.
    Person memory _raj = _person('Raj key');
    Person memory _rajNewKey = _person('Raj new key');
    address _rajAccount = _openAccount(_raj.addr);
    Rule memory _rajRule =
      _rule(_rajAccount, 5 days, false, _thresholds(1), _sizes(1), _credentials(_passport(keccak256('Raj passport'))));
    _setUpRecovery(_rajAccount, _raj, _rajRule);

    // Raj proves his passport over a handover to his new key, and attempt 1 opens.
    bytes memory _rajPayload = _handover(_rajNewKey.addr, _raj.addr);
    IPolicyManager.AttemptRequest memory _rajRequest =
      _request(_rajAccount, _rajRule, _rajPayload, _noPayment(), uint48(block.timestamp + 24 hours));
    _signApproval(_rajRequest, _rajRule, 0);
    _submits(_relayer, _rajRequest);

    // The compromised key admin names a root verifier the attacker controls, keeping the trusted verifier helper. The
    // method refuses the list, naming the fixed router and the proposed one, and the trusted keys stay as they were.
    (,, bytes32[] memory _before,,) = _zkPassportMethod.trustedParties();
    (bytes32[] memory _proposed, address _forger) = _forgerKeys(_rajRule.places[0]);
    vm.prank(_identitySafe);
    vm.expectRevert(
      abi.encodeWithSelector(
        IZkPassportMethod.ZkPassportMethod_RootVerifierChanged.selector, _before[1], bytes32(uint256(uint160(_forger)))
      )
    );
    _zkPassportMethod.setTrustedKeys(_proposed);
    (,, bytes32[] memory _after,,) = _zkPassportMethod.trustedParties();
    assertEq(keccak256(abi.encode(_after)), keccak256(abi.encode(_before)), 'the trusted keys did not move');

    // The attacker, who never held the passport, makes a proof over the cancellation of attempt 1. It is still refused.
    IPolicyManager.CancelRequest memory _cancel =
      _cancelRequest(_rajAccount, _rajRule, 1, uint48(block.timestamp + 24 hours));
    bytes memory _forgedProof = _passportProof(keccak256('no passport'), _manager.hashCancel(_cancel, 0));
    _cancel.proofs = new IPolicyManager.ProofPlace[](1);
    _cancel.proofs[0] = _proofPlace(_rajRule, 0, _forgedProof);
    vm.prank(_attacker.addr);
    vm.expectRevert(_proofRejected(0, address(_zkPassportMethod)));
    _manager.cancelByProofs(_cancel);

    // The wait passes, and Raj's handover gives his account to his new key.
    skip(5 days);
    _executes(_executor, _rajAccount, _rajPayload);
    _assertKeyControls(_rajAccount, _rajNewKey, 'Raj new key');
    assertEq(_privilegeOf(_rajAccount, _attacker.addr), bytes32(0), 'the attacker holds nothing');
  }

  /*///////////////////////////////////////////////////////////////
                              UTILITIES
  ///////////////////////////////////////////////////////////////*/

  /// @notice The list a compromised key admin would set: the current trusted keys with, as the root verifier, one
  ///         that answers every proof with the credential's identifier, keeping the verifier helper the method trusts.
  function _forgerKeys(Credential memory _credential) internal returns (bytes32[] memory _keys, address _forger) {
    (bytes32 _identifier,,,) = abi.decode(_credential.config, (bytes32, string, string, uint256));
    (,, _keys,,) = _zkPassportMethod.trustedParties();
    _forger = address(
      new RootVerifierTheKeyAdminControls(_identifier, IZkPassportVerifierHelper(address(uint160(uint256(_keys[3])))))
    );
    _keys[1] = bytes32(uint256(uint160(_forger)));
  }

  /// @notice zkPassport's upstream admin routes a release with a derivation and retires the previous release.
  function _zkPassportShips(bytes32 _previous, bytes32 _version, bytes32 _derivation) internal {
    IDeployIdentity.Pins memory _pins = _identityScript.pinsFor(block.chainid);
    LocalZkPassportRootVerifier _root = LocalZkPassportRootVerifier(_pins.rootVerifier);
    vm.prank(LocalIdentityRoles.ROOT_ADMIN);
    _root.addVersion(_version, _pins.subVerifier, _pins.verifierHelper, _derivation);
    vm.prank(LocalIdentityRoles.ROOT_ADMIN);
    _root.addVersion(_previous, address(0), address(0), bytes32(0));
  }
}
