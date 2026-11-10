// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyManager} from 'interfaces/IPolicyManager.sol';
import {IRecoveryAction} from 'interfaces/IRecoveryAction.sol';
import {IAmbireAccount} from 'contracts/actions/ambire/IAmbireAccount.sol';
import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';
import {
  ActionAmbireAccountFixture,
  ActionRefusingPayee,
  ActionCallbackPayee
} from 'test/mocks/ActionAmbireAccountFixture.sol';
import {ActionSilentAccountMock} from 'test/mocks/ActionAmbireAccountMock.sol';
import {ActionAmbireProxy} from 'test/utils/ActionAmbireProxy.sol';
import {ActionSpendTestBase} from 'test/utils/ActionSpendTestBase.sol';

/// @notice The spend `executeHandover(account, payload)`. Anyone calls it once the wait is over. It
///         reads the manager's attempt as an early exit, refuses a malformed payload, builds the
///         batch consume, grant, revoke and, when the order has an amount, the payment, and hands
///         it to the account's `execute` with the signature that routes the account to this action.
///         In the mocked world the account's `execute` is mocked, so each test reads the exact
///         call the action makes. In the live world a real manager and a transcription of Ambire's
///         account run the batch, so each test reads what a recovery leaves behind.
contract AmbireRecoveryActionExecuteHandoverTest is ActionSpendTestBase {
  address internal _executor;

  function setUp() public override {
    super.setUp();
    _executor = makeAddr('executor');
    _keysReady();
    vm.mockCall(address(_account), abi.encodeWithSelector(IAmbireAccount.execute.selector), '');
  }

  /// @notice A token order paying the default payee.
  function _tokenOrder(uint256 _amount) internal view returns (IPolicyManager.PaymentOrder memory _order) {
    _order = IPolicyManager.PaymentOrder({token: _token, amount: _amount, payee: _payee});
  }

  /// @notice Expects exactly one call to the account's execute, carrying `_calls`, the kit
  ///         signature and no value.
  function _expectExecute(IAmbireRecoveryAction.Transaction[] memory _calls) internal {
    vm.expectCall(
      address(_account), 0, abi.encodeCall(IAmbireAccount.execute, (_calls, _kitSignature(address(_action)))), 1
    );
  }

  /// @notice Expects no call at all to the account.
  function _expectNoAccountCall() internal {
    vm.expectCall(address(_account), bytes(''), 0);
  }

  /// @notice Mocks `_attempt`, expects the refusal naming it, and calls with the default payload.
  function _expectNotConsumable(IPolicyManager.Attempt memory _attempt) internal {
    _mockAttempt(address(_account), _attempt);
    _expectNoAccountCall();
    vm.expectRevert(_notConsumable(address(_account), _attempt));
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice Commits the mocked attempt to `_committed` exactly and expects MalformedHandover
  ///         carrying it, with no call to the account.
  function _expectMalformed(bytes memory _committed) internal {
    _mockAttempt(address(_account), _waiting(_committed, _noPayment()));
    _expectNoAccountCall();
    vm.expectRevert(abi.encodeWithSelector(IRecoveryAction.RecoveryAction_MalformedHandover.selector, _committed));
    vm.prank(_executor);
    _action.executeHandover(address(_account), _committed);
  }

  /// @notice The error the action raises for an account it does not serve.
  function _notServed(address _acct) internal pure returns (bytes memory _err) {
    _err = abi.encodeWithSelector(IRecoveryAction.RecoveryAction_AccountNotServed.selector, _acct);
  }

  /// @notice Mocks a consumable attempt for `_acct` committed to the default handover, expects the
  ///         manager's attempt never to be read and the account never to be called, and expects the
  ///         refusal naming `_acct`.
  function _expectNotServedBeforeAnyRead(address _acct) internal {
    _mockAttempt(_acct, _waiting(_payload(_newKey, _removedKey), _noPayment()));
    vm.expectCall(_manager, abi.encodeWithSelector(IPolicyManager.stateOf.selector), 0);
    vm.expectCall(_acct, bytes(''), 0);
    vm.expectRevert(_notServed(_acct));
    vm.prank(_executor);
    _action.executeHandover(_acct, _payload(_newKey, _removedKey));
  }

  /// @notice Expects the live account, with a consumable attempt for the default handover, to be
  ///         refused as unserved, and then finds its keys and its attempt as they were.
  function _expectLiveNotServed() internal {
    vm.expectCall(_live, abi.encodeWithSelector(IAmbireAccount.execute.selector), 0);
    vm.expectRevert(_notServed(_live));
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    assertEq(_livePrivilege(_newKey), bytes32(0), 'the new key holds nothing');
    assertEq(_livePrivilege(_removedKey), _SIGNER_VALUE, 'the removed key keeps its value');
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Waiting), 'the attempt still waits');
  }

  /*///////////////////////////////////////////////////////////////
                            THE ACCOUNT
  ///////////////////////////////////////////////////////////////*/

  /// @notice An account built as Ambire's 45-byte proxy, but over an implementation other than the
  ///         one the action pins, is refused before anything runs, even though that implementation
  ///         speaks Ambire's interface and would run the batch. The action vouches for one
  ///         implementation's privilege rules only. The other implementation carries a copy of
  ///         Ambire's account code at another address.
  function test_RevertWhen_TheAccountIsAProxyOverAnotherImplementation() external {
    _buildLiveWorld();
    _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    address _otherImplementation = makeAddr('otherImplementation');
    vm.etch(_otherImplementation, address(new ActionAmbireAccountFixture()).code);
    vm.etch(_live, _servedProxyRuntime(_otherImplementation));
    // it should revert
    // it should leave every privilege and the attempt as they were
    _expectLiveNotServed();
  }

  /// @notice An account whose fallback accepts any call and returns nothing is refused before the
  ///         attempt is read and before any call to it, rather than returning as if the handover
  ///         ran while nothing changed and the attempt kept waiting.
  function test_RevertWhen_TheAccountAcceptsAnyCallAndReturnsNothing() external {
    address _silent = address(new ActionSilentAccountMock());
    // it should revert
    // it should read no attempt and call no account
    _expectNotServedBeforeAnyRead(_silent);
  }

  /// @notice A key that delegates by EIP-7702 to the very implementation the action pins is refused:
  ///         its code is the 23-byte designator, not the proxy, and the delegating key would keep
  ///         signing after a handover that read as complete.
  function test_RevertWhen_TheAccountDelegatesToTheServedImplementation() external {
    _buildLiveWorld();
    _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    vm.etch(_live, ActionAmbireProxy.designator(_liveImplementation));
    assertEq(_live.code.length, 23, 'fixture: the account is a delegation designator');
    // it should revert
    // it should leave every privilege and the attempt as they were
    _expectLiveNotServed();
  }

  /// @notice An address with no code is refused before the attempt is read, since a call to it
  ///         would return as if the batch ran.
  function test_RevertWhen_TheAccountHasNoCode() external {
    address _codeless = makeAddr('codelessAccount');
    // it should revert
    // it should read no attempt and call no account
    _expectNotServedBeforeAnyRead(_codeless);
  }

  /*///////////////////////////////////////////////////////////////
                          THE EARLY EXIT
  ///////////////////////////////////////////////////////////////*/

  /// @notice An account for which the real manager never recorded an attempt is refused with the
  ///         empty record's state, clock and hash, None, 0 and 0, and the account's execute is never
  ///         called, so nothing reaches the account without an attempt.
  function test_RevertWhen_NoAttemptWasEverRecorded() external {
    _buildLiveWorld();
    IPolicyManager.Attempt memory _none;
    _none.usedMethods = new address[](0);
    vm.expectCall(_live, abi.encodeWithSelector(IAmbireAccount.execute.selector), 0);
    // it should revert
    // it should carry the attempt's state, clock and hash before any account call
    vm.expectRevert(_notConsumable(_live, _none));
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
  }

  /// @notice A cancelled attempt is refused before any account call, whatever it committed.
  function test_RevertWhen_TheAttemptWasCancelled() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _noPayment());
    _attempt.state = IPolicyManager.AttemptState.Cancelled;
    // it should revert
    // it should carry the attempt's state, clock and hash before any account call
    _expectNotConsumable(_attempt);
  }

  /// @notice A consumed attempt is refused before any account call, so a spent approval is never
  ///         handed to the account again by this path.
  function test_RevertWhen_TheAttemptWasConsumed() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _noPayment());
    _attempt.state = IPolicyManager.AttemptState.Consumed;
    // it should revert
    // it should carry the attempt's state, clock and hash before any account call
    _expectNotConsumable(_attempt);
  }

  /// @notice Any wait that ends after now, one second from now included, is refused before any
  ///         account call, so the holder's window to cancel is never cut short. `_remaining` is
  ///         bounded to 1 second through the last representable time.
  function testFuzz_RevertWhen_TheWaitIsNotOver(uint256 _remaining) external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _noPayment());
    _attempt.consumableAfter =
      uint48(block.timestamp + bound(_remaining, 1, uint256(type(uint48).max) - block.timestamp));
    // it should revert
    // it should carry the attempt's state, clock and hash before any account call
    _expectNotConsumable(_attempt);
  }

  /// @notice A payload other than the one the attempt committed is refused before any account call,
  ///         so a caller can never swap the keys the guardians approved.
  function test_RevertWhen_ThePayloadHashesToAnotherCommitment() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, makeAddr('otherRemoved')), _noPayment());
    // it should revert
    // it should carry the attempt's state, clock and hash before any account call
    _expectNotConsumable(_attempt);
  }

  /// @notice The attempt is read for the account named and this action, so one account's approval
  ///         never serves another account.
  function test_WhenTheAttemptIsRead() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _noPayment());
    _mockAttempt(address(_account), _attempt);
    // it should read stateOf for the account and this action
    vm.expectCall(_manager, abi.encodeCall(IPolicyManager.stateOf, (address(_account), address(_action))));
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /*///////////////////////////////////////////////////////////////
                          THE PAYLOAD
  ///////////////////////////////////////////////////////////////*/

  /// @notice A handover installing the zero address would leave no new key, so it is refused with
  ///         the payload it carried.
  function test_RevertWhen_TheNewKeyIsZero() external {
    // it should revert
    // it should carry the payload
    _expectMalformed(_payload(address(0), _removedKey));
  }

  /// @notice A handover removing the zero address would remove nothing, so it is refused.
  function test_RevertWhen_TheRemovedKeyIsZero() external {
    // it should revert
    // it should carry the payload
    _expectMalformed(_payload(_newKey, address(0)));
  }

  /// @notice A handover naming one address on both sides would grant and then revoke it, leaving
  ///         the account without that key, so it is refused. `_key` is any address, zero included.
  function testFuzz_RevertWhen_BothKeysAreTheSameAddress(address _key) external {
    // it should revert
    // it should carry the payload
    _expectMalformed(_payload(_key, _key));
  }

  /// @notice A payload shorter than the two address words, the empty payload included, does not
  ///         decode in the handover layout. `_length` is bounded to 0 through 63 bytes, each 0x11.
  function testFuzz_RevertWhen_ThePayloadIsShorterThanTwoWords(uint256 _length) external {
    bytes memory _short = new bytes(bound(_length, 0, 63));
    for (uint256 _i; _i < _short.length; ++_i) {
      _short[_i] = 0x11;
    }
    // it should revert
    // it should carry the payload
    _expectMalformed(_short);
  }

  /// @notice A handover of two clean, distinct, nonzero keys cut to 63 bytes, one short of its second
  ///         word, is refused for its length alone, since its first word is a clean address. A
  ///         recovery must never act on a removed key it cannot read whole.
  function test_RevertWhen_ThePayloadStopsOneByteShortOfTwoWords() external {
    address _first = address(uint160(uint256(keccak256('one byte short new key'))));
    address _second = address(uint160(uint256(keccak256('one byte short removed key'))));
    bytes memory _full = _payload(_first, _second);
    bytes memory _cut = new bytes(63);
    for (uint256 _i; _i < 63; ++_i) {
      _cut[_i] = _full[_i];
    }
    // it should revert
    // it should carry the payload
    _expectMalformed(_cut);
  }

  /// @notice A payload whose address word carries bits above the twenty address bytes is no
  ///         handover, so it is refused with the payload it carried and nothing reaches the account.
  function test_RevertWhen_AnAddressWordCarriesHighBits() external {
    bytes memory _dirty =
      abi.encodePacked(uint256(uint160(_newKey)) | (uint256(1) << 200), uint256(uint160(_removedKey)));
    // it should revert
    // it should carry the payload
    _expectMalformed(_dirty);
  }

  /// @notice A payload whose first word is a clean address and whose second word, the removed key,
  ///         carries bits above the twenty address bytes is no handover, so it is refused with the
  ///         payload it carried rather than read as a truncated address. `_highSeed` picks the upper
  ///         96 bits of that word, bounded so at least one of them is set.
  function testFuzz_RevertWhen_TheRemovedKeyWordCarriesHighBits(uint256 _highSeed) external {
    uint256 _high = bound(_highSeed, 1, type(uint96).max);
    bytes memory _dirty = abi.encodePacked(uint256(uint160(_newKey)), (_high << 160) | uint256(uint160(_removedKey)));
    // it should revert
    // it should carry the payload
    _expectMalformed(_dirty);
  }

  /// @notice A payload with a byte trailing the two addresses decodes cleanly, so it is not
  ///         malformed. The action hands the account the batch the two addresses give, with consume
  ///         naming the committed hash, and the account's check refuses it at the grant, since the
  ///         grant and the revoke rebuild the canonical payload, whose hash differs. The attempt
  ///         keeps waiting.
  function test_WhenThePayloadCarriesATrailingByte() external {
    _buildLiveWorld();
    bytes memory _trailing = abi.encodePacked(_payload(_newKey, _removedKey), bytes1(0x00));
    IPolicyManager.Attempt memory _attempt = _plantLive(_trailing, _noPayment(), 0);
    // it should hand the account the batch the decoded addresses give
    vm.expectCall(
      _live,
      0,
      abi.encodeCall(IAmbireAccount.execute, (_liveBatch(_attempt, address(0)), _kitSignature(address(_liveAction)))),
      1
    );
    // it should be refused by the account's check at index 1
    vm.expectRevert(_notApproved(1));
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _trailing);
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Waiting), 'still waiting');
  }

  /*///////////////////////////////////////////////////////////////
                            THE BATCH
  ///////////////////////////////////////////////////////////////*/

  /// @notice With no amount the account is handed three calls, consume, grant and revoke, and the
  ///         signature that routes it to this action's check, and nothing else.
  function test_WhenTheOrderHasNoAmount() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _noPayment());
    _mockAttempt(address(_account), _attempt);
    // it should hand the account consume, grant and revoke under the kit signature
    _expectExecute(_mockedBatch(_attempt, address(0)));
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice The same batch for any caller, any attempt id and any two distinct nonzero keys, so
  ///         the batch follows the committed attempt and never the caller. `_idSeed` is the attempt
  ///         id, and `_newSeed` and `_removedSeed` are hashed under different tags into two fresh
  ///         addresses, so the new key never names an address the fixture already privileges and
  ///         the two keys never match.
  function testFuzz_WhenTheOrderHasNoAmount(address _caller, uint64 _idSeed, uint256 _newSeed, uint256 _removedSeed)
    external
  {
    address _new = _freshAddress('newKey', _newSeed);
    address _removed = _freshAddress('removedKey', _removedSeed);
    _account.setPrivilege(_removed, _SIGNER_VALUE);
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_new, _removed), _noPayment());
    _attempt.attemptId = _idSeed;
    _mockAttempt(address(_account), _attempt);
    // it should hand the account consume, grant and revoke under the kit signature
    _expectExecute(_approvedBatch(_manager, address(_action), address(_account), _attempt, _new, _removed, address(0)));
    vm.prank(_caller);
    _action.executeHandover(address(_account), _payload(_new, _removed));
  }

  /// @notice The wait ending this very second is over: the comparison is at or past, never after.
  function test_WhenTheWaitEndsThisSecond() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _noPayment());
    _attempt.consumableAfter = uint48(block.timestamp);
    _mockAttempt(address(_account), _attempt);
    // it should hand the account the batch
    _expectExecute(_mockedBatch(_attempt, address(0)));
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice A token order adds a fourth call, a raw transfer of the amount in the token to the
  ///         payee, with no value and not wrapped in any library call.
  function test_WhenTheOrderPaysAToken() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _tokenOrder(12_345));
    _mockAttempt(address(_account), _attempt);
    // it should add a raw token transfer to the payee
    _expectExecute(_mockedBatch(_attempt, _payee));
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice Any token, amount and payee of the order appear in the transfer exactly. `_tokenSeed`
  ///         and `_payeeSeed` build a nonzero token and payee, and `_amount` is bounded to be nonzero.
  function testFuzz_WhenTheOrderPaysAToken(uint256 _tokenSeed, uint256 _amount, uint256 _payeeSeed) external {
    IPolicyManager.PaymentOrder memory _order = IPolicyManager.PaymentOrder({
      token: _addressOtherThan(_tokenSeed, address(0)),
      amount: bound(_amount, 1, type(uint256).max),
      payee: _addressOtherThan(_payeeSeed, address(0))
    });
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _order);
    _mockAttempt(address(_account), _attempt);
    // it should add a raw token transfer to the payee
    _expectExecute(_mockedBatch(_attempt, _order.payee));
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice An order that names a token but no amount pays nobody, so the account is handed the
  ///         three calls consume, grant and revoke, and no transfer of zero rides behind them.
  function test_WhenTheOrderNamesATokenButNoAmount() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _tokenOrder(0));
    _mockAttempt(address(_account), _attempt);
    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](3);
    _calls[0] = _consumeCall(_manager, address(_action), _attempt.attemptId, _attempt.payloadHash);
    _calls[1] = _grantCall(address(_account), _newKey);
    _calls[2] = _revokeCall(address(_account), _removedKey);
    // it should hand the account consume, grant and revoke only
    _expectExecute(_calls);
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice A native order adds a fourth call to the payee carrying the amount and no data.
  function test_WhenTheOrderPaysTheNativeAsset() external {
    IPolicyManager.PaymentOrder memory _order =
      IPolicyManager.PaymentOrder({token: address(0), amount: 1 ether, payee: _payee});
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _order);
    _mockAttempt(address(_account), _attempt);
    // it should add a value call to the payee with no data
    _expectExecute(_mockedBatch(_attempt, _payee));
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice An open token order, one with no payee, pays whoever called, the one place where the
  ///         caller is read. `_caller` is any address, the zero address included, since an open
  ///         order that ends up paying nobody still runs the handover.
  function testFuzz_WhenAnOpenTokenOrderIsExecuted(address _caller) external {
    IPolicyManager.PaymentOrder memory _order =
      IPolicyManager.PaymentOrder({token: _token, amount: 5, payee: address(0)});
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _order);
    _mockAttempt(address(_account), _attempt);
    // it should transfer the token to the caller
    _expectExecute(_mockedBatch(_attempt, _caller));
    vm.prank(_caller);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice An open native order sends the amount to whoever called. `_caller` is any address, the
  ///         zero address included, which the account skips rather than pays.
  function testFuzz_WhenAnOpenNativeOrderIsExecuted(address _caller) external {
    IPolicyManager.PaymentOrder memory _order =
      IPolicyManager.PaymentOrder({token: address(0), amount: 5, payee: address(0)});
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _removedKey), _order);
    _mockAttempt(address(_account), _attempt);
    // it should send the amount to the caller
    _expectExecute(_mockedBatch(_attempt, _caller));
    vm.prank(_caller);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /// @notice When the account's execute reverts, so does the spend, so a caller never sees a
  ///         success for a batch that did not run.
  function test_RevertWhen_TheAccountRefusesTheBatch() external {
    _mockAttempt(address(_account), _waiting(_payload(_newKey, _removedKey), _noPayment()));
    vm.mockCallRevert(address(_account), abi.encodeWithSelector(IAmbireAccount.execute.selector), 'refused');
    // it should revert
    vm.expectRevert();
    vm.prank(_executor);
    _action.executeHandover(address(_account), _payload(_newKey, _removedKey));
  }

  /*///////////////////////////////////////////////////////////////
                    THE LIVE ACCOUNT RUNS THE BATCH
  ///////////////////////////////////////////////////////////////*/

  /// @notice On an account built like Ambire's, the batch spends the attempt, writes 1 for the new
  ///         key, zeroes the removed key and leaves the action authorized. So the recovered holder
  ///         signs, the lost key does not, and the action can serve a later recovery.
  function test_WhenTheLiveAccountRunsTheApprovedBatch() external {
    _buildLiveWorld();
    _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    vm.expectEmit(address(_liveManager));
    emit IPolicyManager.AttemptConsumed(_live, address(_liveAction), 1);
    vm.expectEmit(_live);
    emit IAmbireAccount.LogPrivilegeChanged(_newKey, _KEY_VALUE);
    vm.expectEmit(_live);
    emit IAmbireAccount.LogPrivilegeChanged(_removedKey, bytes32(0));
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    // it should consume the attempt, install the new key at 1 and zero the removed key
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
    assertEq(_livePrivilege(_newKey), _KEY_VALUE, 'new key at the key value');
    assertEq(_livePrivilege(_removedKey), bytes32(0), 'removed key zeroed');
    assertEq(
      _livePrivilege(_expectedKitSlot(address(_liveAction))),
      _expectedBinding(address(_liveAction)),
      'still authorizes the action'
    );
  }

  /// @notice The token order's amount moves from the account to the payee inside the same batch.
  function test_WhenTheLiveOrderPaysAToken() external {
    _buildLiveWorld();
    _plantLive(
      _payload(_newKey, _removedKey),
      IPolicyManager.PaymentOrder({token: address(_liveToken), amount: 777, payee: _payee}),
      0
    );
    uint256 _before = _liveToken.balanceOf(_live);
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    // it should pay the payee the amount in the token
    assertEq(_liveToken.balanceOf(_payee), 777, 'payee paid');
    assertEq(_liveToken.balanceOf(_live), _before - 777, 'account paid exactly the amount');
    assertEq(_livePrivilege(_newKey), _KEY_VALUE, 'the handover ran');
  }

  /// @notice The native order's amount moves from the account to the payee.
  function test_WhenTheLiveOrderPaysTheNativeAsset() external {
    _buildLiveWorld();
    _plantLive(
      _payload(_newKey, _removedKey),
      IPolicyManager.PaymentOrder({token: address(0), amount: 3 ether, payee: _payee}),
      0
    );
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    // it should pay the payee the amount in the native asset
    assertEq(_payee.balance, 3 ether, 'payee paid');
    assertEq(_live.balance, 97 ether, 'account paid exactly the amount');
  }

  /// @notice An open order pays whoever sent executeHandover.
  function test_WhenTheLiveOpenOrderPaysTheCaller() external {
    _buildLiveWorld();
    _plantLive(
      _payload(_newKey, _removedKey),
      IPolicyManager.PaymentOrder({token: address(_liveToken), amount: 55, payee: address(0)}),
      0
    );
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    // it should pay the caller
    assertEq(_liveToken.balanceOf(_executor), 55, 'caller paid');
  }

  /// @notice A token that answers false instead of reverting pays nobody and the handover still
  ///         runs, because the payment is a raw call and a wrapper that checks the answer would cost
  ///         the holder a handover that should have run.
  function test_WhenTheLiveTokenAnswersFalse() external {
    _buildLiveWorld();
    _liveToken.setAnswersFalse(true);
    _plantLive(
      _payload(_newKey, _removedKey),
      IPolicyManager.PaymentOrder({token: address(_liveToken), amount: 777, payee: _payee}),
      0
    );
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    // it should complete the handover and pay nobody
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
    assertEq(_livePrivilege(_newKey), _KEY_VALUE, 'new key installed');
    assertEq(_liveToken.balanceOf(_payee), 0, 'nobody paid');
  }

  /// @notice A token order whose token address holds no code pays nobody, and the handover still
  ///         runs, because the payment is a raw call and a call to an address without code
  ///         succeeds. No balance moves.
  function test_WhenTheLiveOrderTokenHasNoCode() external {
    _buildLiveWorld();
    address _noCode = makeAddr('tokenWithoutCode');
    _plantLive(
      _payload(_newKey, _removedKey), IPolicyManager.PaymentOrder({token: _noCode, amount: 777, payee: _payee}), 0
    );
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    // it should complete the handover and move no balance
    _assertRanWithNothingPaid();
  }

  /// @notice A token order whose token returns no data at all, code that stops at once, pays
  ///         nobody, and the handover still runs, for the same reason as a token answering false.
  ///         No balance moves.
  function test_WhenTheLiveOrderTokenReturnsNoData() external {
    _buildLiveWorld();
    address _silent = makeAddr('tokenReturningNothing');
    // runtime of one STOP opcode: every call succeeds and returns no data
    vm.etch(_silent, hex'00');
    _plantLive(
      _payload(_newKey, _removedKey), IPolicyManager.PaymentOrder({token: _silent, amount: 777, payee: _payee}), 0
    );
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    // it should complete the handover and move no balance
    _assertRanWithNothingPaid();
  }

  /// @notice Checks a live handover ran, the attempt consumed, the new key at the key value and
  ///         the removed key zeroed, while the account kept its 100 ether and its 1e24 token units
  ///         and the payee received nothing.
  function _assertRanWithNothingPaid() internal view {
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
    assertEq(_livePrivilege(_newKey), _KEY_VALUE, 'new key installed');
    assertEq(_livePrivilege(_removedKey), bytes32(0), 'removed key zeroed');
    assertEq(_live.balance, 100 ether, 'account native unchanged');
    assertEq(_liveToken.balanceOf(_live), 1e24, 'account tokens unchanged');
    assertEq(_payee.balance, 0, 'payee paid nothing in the native asset');
    assertEq(_liveToken.balanceOf(_payee), 0, 'payee paid nothing in the token');
  }

  /// @notice A payee that refuses the payment reverts the whole batch: nothing is spent, no key
  ///         moves, and the attempt keeps waiting for a cancel.
  function test_RevertWhen_TheLivePayeeRefusesThePayment() external {
    _buildLiveWorld();
    address _refusing = address(new ActionRefusingPayee());
    _plantLive(
      _payload(_newKey, _removedKey),
      IPolicyManager.PaymentOrder({token: address(0), amount: 1 ether, payee: _refusing}),
      0
    );
    // it should revert
    // it should undo the whole batch and leave the attempt waiting
    vm.expectRevert(ActionRefusingPayee.ActionRefusingPayee_Refused.selector);
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Waiting), 'still waiting');
    assertEq(_livePrivilege(_newKey), bytes32(0), 'no grant');
    assertEq(_livePrivilege(_removedKey), _SIGNER_VALUE, 'no revoke');
  }

  /// @notice A payee that calls the account again with the same batch while it is being paid finds
  ///         the approval already spent: the nested run reverts whole with the consumed attempt's
  ///         refusal, and the outer handover runs once.
  function test_WhenALivePayeeCallsTheAccountAgainWithTheSameBatch() external {
    _buildLiveWorld();
    ActionCallbackPayee _callbackPayee = new ActionCallbackPayee();
    IPolicyManager.Attempt memory _attempt = _plantLive(
      _payload(_newKey, _removedKey),
      IPolicyManager.PaymentOrder({token: address(0), amount: 1 ether, payee: address(_callbackPayee)}),
      0
    );
    _callbackPayee.load(_live, _liveBatch(_attempt, address(_callbackPayee)), _kitSignature(address(_liveAction)));
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    // it should refuse the nested run and complete the outer one once
    assertEq(_callbackPayee.attempts(), 1, 'the payee called the account again');
    assertEq(_callbackPayee.successes(), 0, 'the nested run reverted');
    _attempt.state = IPolicyManager.AttemptState.Consumed;
    assertEq(_callbackPayee.lastRevert(), _notConsumable(_live, _attempt), 'the spent attempt refused it');
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Consumed), 'consumed once');
    assertEq(address(_callbackPayee).balance, 1 ether, 'paid once');
  }

  /// @notice Once a handover has run, running it again is refused as a consumed attempt.
  function test_RevertWhen_TheSameLiveHandoverRunsASecondTime() external {
    _buildLiveWorld();
    IPolicyManager.Attempt memory _attempt = _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    _attempt.state = IPolicyManager.AttemptState.Consumed;
    // it should revert
    // it should refuse it as a consumed attempt
    vm.expectRevert(_notConsumable(_live, _attempt));
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
  }

  /// @notice A new key that gained any privilege during the wait makes the batch revert whole with
  ///         AlreadyPrivileged naming it, so a handover never overwrites an entry.
  function test_RevertWhen_TheLiveNewKeyAlreadyHoldsAPrivilege() external {
    _buildLiveWorld();
    _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    vm.prank(_live);
    IAmbireAccount(_live).setAddrPrivilege(_newKey, _ENTRY_POINT_MARKER);
    // it should revert
    // it should undo the whole batch with AlreadyPrivileged
    vm.expectRevert(abi.encodeWithSelector(IRecoveryAction.RecoveryAction_AlreadyPrivileged.selector, _newKey));
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Waiting), 'still waiting');
  }

  /// @notice A removed key that lost its key value during the wait makes the batch revert whole
  ///         with NotAKey naming it, so a recovery never completes without removing a key.
  function test_RevertWhen_TheLiveRemovedKeyHoldsNoKeyValue() external {
    _buildLiveWorld();
    _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    vm.prank(_live);
    IAmbireAccount(_live).setAddrPrivilege(_removedKey, bytes32(0));
    // it should revert
    // it should undo the whole batch with NotAKey
    vm.expectRevert(abi.encodeWithSelector(IRecoveryAction.RecoveryAction_NotAKey.selector, _removedKey));
    vm.prank(_executor);
    _liveAction.executeHandover(_live, _payload(_newKey, _removedKey));
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Waiting), 'still waiting');
  }
}
