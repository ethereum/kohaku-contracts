// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IPolicyManager} from 'interfaces/IPolicyManager.sol';
import {IPolicyMethodAdmin} from 'interfaces/IPolicyMethodAdmin.sol';

import {PolicyMethodRoles} from 'contracts/methods/roles/PolicyMethodRoles.sol';

import {IntegrationBase} from 'test/integration/base/IntegrationBase.sol';

/// @notice The Safe that holds a role of the Aadhaar method, the key admin or the pause holder, hands it to a new Safe
///         in two steps, so the role never has zero or two holders, and the new Safe can use it at once. The holder's
///         rule is any 2 of Ben's wallet and an Aadhaar guardian.
contract IdentityMethodRoleHandover is IntegrationBase {
  /// @notice Local only: its rule names an identity credential, which no story can prove on a fork.
  function _runsOnForks() internal pure override returns (bool _runs) {
    _runs = false;
  }

  /// @notice The hash of the Aadhaar issuer's next signing key.
  bytes32 internal constant _NEW_ISSUER_KEY = keccak256('UIDAI signing key, local issue 2');
  /// @notice The hash of a key the old admin rotates to while its offer of the role is still open.
  bytes32 internal constant _INTERIM_ISSUER_KEY = keccak256('UIDAI signing key, interim issue');

  /// @notice The holder's account.
  address internal _account;
  /// @notice The holder's rule, as the backup holds it.
  Rule internal _holderRule;
  /// @notice The Safe the role moves to.
  address internal _newSafe;
  /// @notice The Aadhaar method, through the roles every identity method shares.
  PolicyMethodRoles internal _method;

  function setUp() public override {
    super.setUp();
    _newSafe = makeAddr('new identity methods Safe');
    _method = PolicyMethodRoles(address(_aadhaarMethod));
    _account = _openAccount(_originalKey.addr);
    Rule memory _r = _rule(
      _account,
      5 days,
      false,
      _thresholds(2),
      _sizes(2),
      _credentials(
        _walletGuardian(_ben), _aadhaarGuardian(uint256(keccak256('Aadhaar guardian identity')), 4242, 3 days)
      )
    );
    _keep(_holderRule, _r);
    _setUpRecovery(_account, _originalKey, _r);
  }

  /*///////////////////////////////////////////////////////////////
                              THE WALK
  ///////////////////////////////////////////////////////////////*/

  /// @notice The key admin offers the role and still rotates the keys while the offer is open. The new Safe accepts,
  ///         and after the issuer rotates the new admin sets the new key and the holder's request opens, while the old
  ///         admin can no longer set keys. The role had exactly one holder at every moment.
  function test_WhenTheKeyAdminHandsOnTheRole() external {
    bytes32[] memory _keys = new bytes32[](1);
    _keys[0] = _NEW_ISSUER_KEY;

    // The key admin sends transferAdmin to offer the role to the new Safe.
    vm.prank(_identitySafe);
    _method.transferAdmin(_newSafe);

    // Until it accepts, the new Safe cannot set keys, and the old admin still holds the role.
    vm.prank(_newSafe);
    vm.expectPartialRevert(IPolicyMethodAdmin.PolicyMethodRoles_AdminUnauthorizedAccount.selector);
    _method.setTrustedKeys(_keys);
    (address _admin,,,,) = _method.trustedParties();
    assertEq(_admin, _identitySafe, 'the old admin holds the role until the offer is accepted');

    // While the offer is open the old admin still rotates the trusted keys.
    bytes32[] memory _interim = new bytes32[](1);
    _interim[0] = _INTERIM_ISSUER_KEY;
    vm.prank(_identitySafe);
    _method.setTrustedKeys(_interim);
    (,, bytes32[] memory _stored,,) = _method.trustedParties();
    assertEq(_stored.length, 1, 'one issuer key');
    assertEq(_stored[0], _INTERIM_ISSUER_KEY, 'the old admin rotated while its offer was open');

    // The new Safe sends acceptAdmin.
    vm.prank(_newSafe);
    _method.acceptAdmin();

    // The issuer rotates its key, and the guardian downloads a fresh QR signed under it.
    _downloadQr(_holderRule.places[1], _NEW_ISSUER_KEY, block.timestamp);

    // The new admin sends setTrustedKeys, and the holder's request with the fresh QR opens.
    vm.prank(_newSafe);
    _method.setTrustedKeys(_keys);
    _submits(_relayer, _approversApprove());
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Waiting), 'the request opened');

    // The old admin sends setTrustedKeys. It fails, and the new admin's keys stay.
    vm.prank(_identitySafe);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyMethodAdmin.PolicyMethodRoles_AdminUnauthorizedAccount.selector, _identitySafe)
    );
    _method.setTrustedKeys(_interim);
    (,, _stored,,) = _method.trustedParties();
    assertEq(_stored[0], _NEW_ISSUER_KEY, 'the old admin no longer rotates');
  }

  /// @notice The pause holder offers the role and still stops and lifts while the offer is open. The new Safe
  ///         accepts, stops the method, which refuses the holder's Aadhaar proof, and unpauses it, after which the
  ///         request opens, while the old pause holder can no longer stop or lift anything.
  function test_WhenThePauseHolderHandsOnTheRole() external {
    // The pause holder offers the role to the new Safe.
    vm.prank(_identitySafe);
    _method.transferOwnership(_newSafe);

    // Until it accepts, the new Safe cannot stop the method.
    vm.prank(_newSafe);
    vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
    _method.pause();

    // While the offer is open the old pause holder still stops the method and lifts the stop.
    vm.prank(_identitySafe);
    _method.pause();
    assertTrue(_method.paused(), 'the old pause holder stopped the method while its offer was open');
    vm.prank(_identitySafe);
    _method.unpause();
    assertFalse(_method.paused(), 'the old pause holder lifted the stop while its offer was open');

    // The new Safe accepts.
    vm.prank(_newSafe);
    _method.acceptOwnership();

    // The new Safe stops the method, and the holder's request with an Aadhaar proof is refused.
    vm.prank(_newSafe);
    _method.pause();
    IPolicyManager.AttemptRequest memory _req = _approversApprove();
    vm.prank(_relayer);
    vm.expectPartialRevert(IPolicyManager.PolicyManager_MethodStopped.selector);
    _manager.startAttempt(_req);

    // The old pause holder tries to lift the new Safe's stop. It fails, and the method stays stopped.
    vm.prank(_identitySafe);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _identitySafe));
    _method.unpause();
    assertTrue(_method.paused(), 'the old pause holder no longer lifts a stop');

    // The new Safe unpauses the method, and the request opens.
    vm.prank(_newSafe);
    _method.unpause();
    _submits(_relayer, _req);
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Waiting), 'the request opened');

    // The old pause holder tries to stop the method. It fails, and the method stays running.
    vm.prank(_identitySafe);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _identitySafe));
    _method.pause();
    assertFalse(_method.paused(), 'the old pause holder no longer stops the method');
  }

  /*///////////////////////////////////////////////////////////////
                             TRADE-OFFS
  ///////////////////////////////////////////////////////////////*/

  /// @notice After renounceAdmin nobody can rotate, so the issuer's next rotation strands every Aadhaar credential:
  ///         the keyless holder who needs the guardian can never open a recovery.
  function test_WhenTheKeyAdminRenounces() external {
    bytes32[] memory _keys = new bytes32[](1);
    _keys[0] = _NEW_ISSUER_KEY;

    // The key admin renounces.
    vm.prank(_identitySafe);
    _method.renounceAdmin();

    // The issuer rotates, and the guardian's fresh QR is signed under the new key.
    _downloadQr(_holderRule.places[1], _NEW_ISSUER_KEY, block.timestamp);

    // Nobody can set the new key: neither the old admin nor the zero address.
    vm.prank(_identitySafe);
    vm.expectPartialRevert(IPolicyMethodAdmin.PolicyMethodRoles_AdminUnauthorizedAccount.selector);
    _method.setTrustedKeys(_keys);
    vm.prank(address(0));
    vm.expectPartialRevert(IPolicyMethodAdmin.PolicyMethodRoles_AdminUnauthorizedAccount.selector);
    _method.setTrustedKeys(_keys);

    // A year later Ben and the identity guardian approve a handover to the new key, and the request still fails.
    skip(365 days);
    _downloadQr(_holderRule.places[1], _NEW_ISSUER_KEY, block.timestamp);
    IPolicyManager.AttemptRequest memory _req = _approversApprove();
    vm.prank(_relayer);
    vm.expectPartialRevert(IPolicyManager.PolicyManager_ProofRejected.selector);
    _manager.startAttempt(_req);
    assertEq(_privilegeOf(_account, _newKey.addr), bytes32(0), 'the new key never got the account');
  }

  /*///////////////////////////////////////////////////////////////
                              UTILITIES
  ///////////////////////////////////////////////////////////////*/

  /// @notice Ben signs place 0 and the Aadhaar guardian proves place 1 over a handover from the lost key to the new
  ///         key.
  function _approversApprove() internal view returns (IPolicyManager.AttemptRequest memory _req) {
    Rule memory _r = _holderRule;
    _req = _request(
      _account, _r, _handover(_newKey.addr, _originalKey.addr), _noPayment(), uint48(block.timestamp + 24 hours)
    );
    _signApproval(_req, _r, 0);
    _signApproval(_req, _r, 1);
  }
}
