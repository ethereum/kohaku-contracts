// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyManager} from 'interfaces/IPolicyManager.sol';

import {IAmbireAccount} from 'contracts/actions/ambire/IAmbireAccount.sol';

import {IntegrationBase} from 'test/integration/base/IntegrationBase.sol';

/// @notice A fallback handler that, run by the account in its own frame, writes a key back into the account.
/// @dev What it stands for: any contract a key names under the account's 0x6969 entry, which the deployed account
///      runs by delegatecall on every call whose selector it does not know, from any caller. Running in the
///      account's frame, its call to `setAddrPrivilege` comes from the account itself, which is the one caller the
///      account lets write its privilege table.
contract KeyRestoringHandler {
  /// @notice The key the handler writes back.
  address public immutable RESTORED_KEY;

  constructor(address _restoredKey) {
    RESTORED_KEY = _restoredKey;
  }

  /// @notice Writes the restored key back at the signer value 2, from inside the account that runs the handler.
  function restore() external {
    IAmbireAccount(address(this)).setAddrPrivilege(RESTORED_KEY, bytes32(uint256(2)));
  }
}

/// @notice The holder's key once named a fallback handler on the account. A recovery replaces the key and leaves the
///         handler where it is, so the handler can write the lost key back afterwards, until the new key clears the
///         handler's entry. The story runs on the local chain and, under INTEGRATION_FORK, on Ambire's deployed
///         implementation.
contract FallbackHandlerSurvivesRecovery is IntegrationBase {
  /// @notice The privilege key whose entry names the account's fallback handler.
  address internal constant _HANDLER_SLOT = address(0x6969);

  /// @notice The holder's account.
  address internal _account;
  /// @notice The holder's rule, as the backup holds it.
  Rule internal _holderRule;
  /// @notice The handler the holder's key installed, which writes the holder's original key back.
  KeyRestoringHandler internal _handler;

  function setUp() public override {
    super.setUp();
    _account = _openAccount(_originalKey.addr);
    _handler = new KeyRestoringHandler(_originalKey.addr);
    Rule memory _r = _mayaRule(_account);
    _keep(_holderRule, _r);
    // The original key names the handler, binds the kit and commits Maya's rule.
    _keySignsAndRelayerSends(
      _account,
      _originalKey,
      _batch(
        _setPrivilegeCall(_account, _HANDLER_SLOT, bytes32(uint256(uint160(address(_handler))))),
        _bindKitCall(_account),
        _commitCall(_account, _r, 1)
      )
    );
  }

  /*///////////////////////////////////////////////////////////////
                              THE WALK
  ///////////////////////////////////////////////////////////////*/

  /// @notice A completed recovery leaves the handler's entry in place, and anyone's call to an unknown selector then
  ///         runs it, which writes the lost key back. A handler outlives the key that installed it, so a recovery
  ///         alone does not remove every authority over the account.
  function test_WhenAHandlerOutlivesTheRecovery() external {
    _recover();

    // The handler's entry survives the handover.
    assertEq(
      _privilegeOf(_account, _HANDLER_SLOT), bytes32(uint256(uint160(address(_handler)))), 'the handler stays named'
    );

    // Anyone calls the account with the handler's selector, which the account does not know.
    vm.prank(makeAddr('anyone'));
    (bool _ok,) = _account.call(abi.encodeCall(KeyRestoringHandler.restore, ()));
    assertTrue(_ok, 'the handled call succeeds');

    // The lost key is back and signs again, beside the new key.
    assertEq(_privilegeOf(_account, _originalKey.addr), _SIGNER_PRIVILEGE, 'the handler wrote the lost key back');
    _assertKeyControls(_account, _originalKey, 'the restored lost key');
    _assertKeyControls(_account, _newKey, 'the new key');
  }

  /// @notice The new key's first write clears the handler's entry. The same call then runs nothing, and the lost key
  ///         stays out. Clearing the entry with the new key first is what closes this path after a recovery.
  function test_WhenTheNewKeyClearsTheHandlerFirst() external {
    _recover();

    // The new key's first write clears the handler's entry.
    _keySignsAndRelayerSends(_account, _newKey, _batch(_setPrivilegeCall(_account, _HANDLER_SLOT, bytes32(0))));
    assertEq(_privilegeOf(_account, _HANDLER_SLOT), bytes32(0), 'the handler entry is cleared');

    // Anyone calls the account with the handler's selector. The call is accepted and does nothing.
    vm.prank(makeAddr('anyone'));
    (bool _ok, bytes memory _returned) = _account.call(abi.encodeCall(KeyRestoringHandler.restore, ()));
    assertTrue(_ok, 'the unknown call is accepted');
    assertEq(_returned.length, 0, 'the unknown call returns nothing');

    // The lost key stays out, and the new key keeps the account.
    assertEq(_privilegeOf(_account, _originalKey.addr), bytes32(0), 'the lost key holds nothing');
    _assertKeyLocked(_account, _originalKey);
    _assertKeyControls(_account, _newKey, 'the new key');
  }

  /*///////////////////////////////////////////////////////////////
                              UTILITIES
  ///////////////////////////////////////////////////////////////*/

  /// @notice Ben, Carla and Maya's passkey approve handing the account from the original key to the new key, a friend
  ///         submits, the wait passes, and anyone executes. The original key is locked out and the new key is in.
  function _recover() internal {
    Rule memory _r = _holderRule;
    bytes memory _payload = _handover(_newKey.addr, _originalKey.addr);
    IPolicyManager.AttemptRequest memory _req =
      _request(_account, _r, _payload, _noPayment(), uint48(block.timestamp + 24 hours));
    _signApproval(_req, _r, 1);
    _signApproval(_req, _r, 2);
    _signApproval(_req, _r, 4);
    _submits(_friend, _req);
    skip(_r.wait);
    _executes(_executor, _account, _payload);
    _assertKeyLocked(_account, _originalKey);
    _assertKeyControls(_account, _newKey, 'the new key');
  }
}
