// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyManager} from 'interfaces/IPolicyManager.sol';
import {IRecoveryAction} from 'interfaces/IRecoveryAction.sol';
import {IAmbireAccount} from 'contracts/actions/ambire/IAmbireAccount.sol';
import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';
import {ActionAmbireAccountFixture} from 'test/mocks/ActionAmbireAccountFixture.sol';
import {ActionAmbireAccountMock} from 'test/mocks/ActionAmbireAccountMock.sol';
import {ActionAmbireProxy} from 'test/utils/ActionAmbireProxy.sol';
import {ActionSpendTestBase} from 'test/utils/ActionSpendTestBase.sol';

/// @notice The account's callback `validateSig(data, innerSignature, calls)`. The account asks it,
///         in its own name, before running a batch sent under the kit slot, and it is the only check
///         between that batch and the account, since the signature that routes the batch here is a
///         constant anyone can build. It answers (true, 0) for exactly the batch the waiting attempt
///         approves, consume, grant, revoke and the payment when the order has an amount, and
///         reverts with a named error for anything else. In the mocked world the test calls it as
///         the account, over a mocked stateOf answer and the privilege-table mock. In the live
///         world the account transcription calls it from inside execute.
contract AmbireRecoveryActionValidateSigTest is ActionSpendTestBase {
  /// @notice The attempt of the default three-call handover.
  IPolicyManager.Attempt internal _plain;

  function setUp() public override {
    super.setUp();
    _keysReady();
    _plain = _waiting(_payload(_newKey, _removedKey), _noPayment());
  }

  /// @notice Asks the action, as the account, about `_calls`, with empty data and inner signature.
  function _ask(IAmbireRecoveryAction.Transaction[] memory _calls) internal returns (bool _ok, uint256 _validAfter) {
    vm.prank(address(_account));
    (_ok, _validAfter) = _action.validateSig('', '', _calls);
  }

  /// @notice Mocks `_attempt`, expects `_err`, and asks about `_calls`.
  function _expectRefusal(
    IPolicyManager.Attempt memory _attempt,
    IAmbireRecoveryAction.Transaction[] memory _calls,
    bytes memory _err
  ) internal {
    _mockAttempt(address(_account), _attempt);
    vm.expectRevert(_err);
    _ask(_calls);
  }

  /// @notice Expects the default three-call batch, altered by the test, to be refused at `_index`.
  function _expectPlainRefusedAt(IAmbireRecoveryAction.Transaction[] memory _calls, uint256 _index) internal {
    _expectRefusal(_plain, _calls, _notApproved(_index));
  }

  /// @notice The default three-call batch.
  function _plainBatch() internal view returns (IAmbireRecoveryAction.Transaction[] memory _calls) {
    _calls = _mockedBatch(_plain, address(0));
  }

  /// @notice An order paying `_amount` of the default token to the default payee.
  function _tokenAttempt(uint256 _amount) internal view returns (IPolicyManager.Attempt memory _attempt) {
    _attempt = _waiting(
      _payload(_newKey, _removedKey), IPolicyManager.PaymentOrder({token: _token, amount: _amount, payee: _payee})
    );
  }

  /// @notice An order paying `_amount` of the native asset to the default payee.
  function _nativeAttempt(uint256 _amount) internal view returns (IPolicyManager.Attempt memory _attempt) {
    _attempt = _waiting(
      _payload(_newKey, _removedKey), IPolicyManager.PaymentOrder({token: address(0), amount: _amount, payee: _payee})
    );
  }

  /// @notice Expects the approved batch of `_attempt`, with its fourth call replaced by `_payment`,
  ///         to be refused at index 3.
  function _expectPaymentRefused(
    IPolicyManager.Attempt memory _attempt,
    IAmbireRecoveryAction.Transaction memory _payment
  ) internal {
    IAmbireRecoveryAction.Transaction[] memory _calls = _mockedBatch(_attempt, _attempt.order.payee);
    _calls[3] = _payment;
    _expectRefusal(_attempt, _calls, _notApproved(3));
  }

  /// @notice A copy of an order, so a test can alter it and keep the attempt's own.
  function _orderCopy(IPolicyManager.PaymentOrder memory _order)
    internal
    pure
    returns (IPolicyManager.PaymentOrder memory _copyOfOrder)
  {
    _copyOfOrder = IPolicyManager.PaymentOrder({token: _order.token, amount: _order.amount, payee: _order.payee});
  }

  /// @notice A batch of `_length` calls to the zero address, none of them any approved call.
  function _junk(uint256 _length) internal pure returns (IAmbireRecoveryAction.Transaction[] memory _calls) {
    _calls = new IAmbireRecoveryAction.Transaction[](_length);
  }

  /*///////////////////////////////////////////////////////////////
                          THE APPROVED BATCH
  ///////////////////////////////////////////////////////////////*/

  /// @notice The exact three-call batch of an order with no amount is approved, and the second
  ///         value, the timestamp the account compares only on a refusal, is zero.
  function test_WhenTheBatchIsTheApprovedOneWithNoPayment() external {
    _mockAttempt(address(_account), _plain);
    (bool _ok, uint256 _validAfter) = _ask(_plainBatch());
    // it should return true and zero
    assertTrue(_ok, 'approved');
    assertEq(_validAfter, 0, 'no timestamp');
  }

  /// @notice The same for any attempt id, any committed pair of distinct nonzero keys and either
  ///         key value, 1 or 2, on the removed key. `_idSeed` is the attempt id, `_newSeed` and
  ///         `_removedSeed` are hashed under different tags into two fresh addresses, so the new key
  ///         never names an address the fixture already privileges and the two keys never match,
  ///         and `_valueSeed` picks 1 or 2.
  function testFuzz_WhenTheBatchIsTheApprovedOneWithNoPayment(
    uint64 _idSeed,
    uint256 _newSeed,
    uint256 _removedSeed,
    uint256 _valueSeed
  ) external {
    address _new = _freshAddress('newKey', _newSeed);
    address _removed = _freshAddress('removedKey', _removedSeed);
    _account.setPrivilege(_removed, bytes32(bound(_valueSeed, 1, 2)));
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_new, _removed), _noPayment());
    _attempt.attemptId = _idSeed;
    _mockAttempt(address(_account), _attempt);
    (bool _ok, uint256 _validAfter) =
      _ask(_approvedBatch(_manager, address(_action), address(_account), _attempt, _new, _removed, address(0)));
    // it should return true and zero
    assertTrue(_ok, 'approved');
    assertEq(_validAfter, 0, 'no timestamp');
  }

  /// @notice A wait that ends this very second is over.
  function test_WhenTheWaitEndsThisSecond() external {
    _plain.consumableAfter = uint48(block.timestamp);
    _mockAttempt(address(_account), _plain);
    (bool _ok, uint256 _validAfter) = _ask(_plainBatch());
    // it should return true and zero
    assertTrue(_ok);
    assertEq(_validAfter, 0);
  }

  /// @notice The action reads nothing from the validator data or the inner signature, so any bytes
  ///         there leave the answer unchanged.
  function testFuzz_WhenTheDataAndTheInnerSignatureCarryAnyBytes(bytes calldata _data, bytes calldata _inner) external {
    _mockAttempt(address(_account), _plain);
    vm.prank(address(_account));
    (bool _ok, uint256 _validAfter) = _action.validateSig(_data, _inner, _plainBatch());
    // it should return true and zero
    assertTrue(_ok);
    assertEq(_validAfter, 0);
  }

  /// @notice The attempt is read for the caller, the account asking in its own name, under this
  ///         action.
  function test_WhenTheAttemptIsRead() external {
    _mockAttempt(address(_account), _plain);
    // it should read stateOf for the caller and this action
    vm.expectCall(_manager, abi.encodeCall(IPolicyManager.stateOf, (address(_account), address(_action))));
    _ask(_plainBatch());
  }

  /// @notice The four-call batch of a token order is approved when its fourth call is the raw
  ///         transfer of the amount in the token to the payee.
  function test_WhenTheBatchCarriesTheApprovedTokenPayment() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(12_345);
    _mockAttempt(address(_account), _attempt);
    (bool _ok, uint256 _validAfter) = _ask(_mockedBatch(_attempt, _payee));
    // it should return true and zero
    assertTrue(_ok);
    assertEq(_validAfter, 0);
  }

  /// @notice The four-call batch of a native order is approved when its fourth call sends the
  ///         amount to the payee with no data.
  function test_WhenTheBatchCarriesTheApprovedNativePayment() external {
    IPolicyManager.Attempt memory _attempt = _nativeAttempt(1 ether);
    _mockAttempt(address(_account), _attempt);
    (bool _ok, uint256 _validAfter) = _ask(_mockedBatch(_attempt, _payee));
    // it should return true and zero
    assertTrue(_ok);
    assertEq(_validAfter, 0);
  }

  /// @notice An open token order leaves the payee free, so a transfer to any payee is approved.
  ///         `_payee` is any address, the zero address included, since whoever builds the batch
  ///         chooses it and a transfer to nobody still lets the handover run.
  function testFuzz_WhenAnOpenTokenOrderNamesAnyPayee(address _payee) external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(5);
    _attempt.order.payee = address(0);
    _mockAttempt(address(_account), _attempt);
    (bool _ok,) = _ask(_mockedBatch(_attempt, _payee));
    // it should return true and zero
    assertTrue(_ok);
  }

  /// @notice An open native order leaves the payee free, so a value call to any payee is approved.
  ///         `_payee` is any address, the zero address included, which the account skips rather
  ///         than pays.
  function testFuzz_WhenAnOpenNativeOrderNamesAnyPayee(address _payee) external {
    IPolicyManager.Attempt memory _attempt = _nativeAttempt(5);
    _attempt.order.payee = address(0);
    _mockAttempt(address(_account), _attempt);
    (bool _ok,) = _ask(_mockedBatch(_attempt, _payee));
    // it should return true and zero
    assertTrue(_ok);
  }

  /// @notice An order that names a token but no amount pays nobody, so the three calls consume,
  ///         grant and revoke are the whole approved batch.
  function test_WhenTheOrderNamesATokenButNoAmount() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(0);
    _mockAttempt(address(_account), _attempt);
    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](3);
    _calls[0] = _consumeCall(_manager, address(_action), _attempt.attemptId, _attempt.payloadHash);
    _calls[1] = _grantCall(address(_account), _newKey);
    _calls[2] = _revokeCall(address(_account), _removedKey);
    (bool _ok, uint256 _validAfter) = _ask(_calls);
    // it should return true and zero
    assertTrue(_ok, 'approved');
    assertEq(_validAfter, 0, 'no timestamp');
  }

  /*///////////////////////////////////////////////////////////////
                          THE ATTEMPT
  ///////////////////////////////////////////////////////////////*/

  /// @notice With no attempt recorded, the batch is refused naming the empty record.
  function test_RevertWhen_NoAttemptWasEverRecorded() external {
    IPolicyManager.Attempt memory _none;
    _none.usedMethods = new address[](0);
    // it should revert
    // it should carry the attempt's state, clock and hash
    _expectRefusal(_none, _plainBatch(), _notConsumable(address(_account), _none));
  }

  /// @notice A cancelled attempt approves nothing.
  function test_RevertWhen_TheAttemptWasCancelled() external {
    _plain.state = IPolicyManager.AttemptState.Cancelled;
    // it should revert
    // it should carry the attempt's state, clock and hash
    _expectRefusal(_plain, _plainBatch(), _notConsumable(address(_account), _plain));
  }

  /// @notice A consumed attempt approves nothing, so the same batch never runs twice.
  function test_RevertWhen_TheAttemptWasConsumed() external {
    _plain.state = IPolicyManager.AttemptState.Consumed;
    // it should revert
    // it should carry the attempt's state, clock and hash
    _expectRefusal(_plain, _plainBatch(), _notConsumable(address(_account), _plain));
  }

  /// @notice A wait ending one second from now approves nothing yet.
  function test_RevertWhen_TheWaitIsNotOver() external {
    _plain.consumableAfter = uint48(block.timestamp) + 1;
    // it should revert
    // it should carry the attempt's state, clock and hash
    _expectRefusal(_plain, _plainBatch(), _notConsumable(address(_account), _plain));
  }

  /// @notice Any wait ending after now approves nothing yet. `_remaining` is bounded to 1 second
  ///         through the last representable time.
  function testFuzz_RevertWhen_TheWaitIsNotOver(uint256 _remaining) external {
    uint256 _latest = uint256(type(uint48).max) - block.timestamp;
    _plain.consumableAfter = uint48(block.timestamp + bound(_remaining, 1, _latest));
    // it should revert
    _expectRefusal(_plain, _plainBatch(), _notConsumable(address(_account), _plain));
  }

  /// @notice The account is whoever asks, so another served account asking about this account's
  ///         batch reads its own empty record and is refused, never approved on the account's attempt.
  function test_RevertWhen_AnotherAddressAsks() external {
    address _other = makeAddr('otherAccount');
    vm.etch(_other, _servedProxyRuntime(_implementation));
    IPolicyManager.Attempt memory _none;
    _none.usedMethods = new address[](0);
    _mockAttempt(address(_account), _plain);
    _mockAttempt(_other, _none);
    // it should revert
    // it should name the caller as the account
    vm.expectRevert(_notConsumable(_other, _none));
    vm.prank(_other);
    _action.validateSig('', '', _plainBatch());
  }

  /// @notice Gives `_caller` the table and the waiting attempt the default handover expects, then
  ///         expects the batch that attempt approves for `_caller` to be refused as unserved when
  ///         `_caller` asks. Every check but the account's shape would approve it.
  function _expectNotServedFor(address _caller, bool _writesTable) internal {
    if (_writesTable) ActionAmbireAccountMock(_caller).setPrivilege(_removedKey, _SIGNER_VALUE);
    _mockAttempt(_caller, _plain);
    IAmbireRecoveryAction.Transaction[] memory _calls =
      _approvedBatch(_manager, address(_action), _caller, _plain, _newKey, _removedKey, address(0));
    vm.expectRevert(abi.encodeWithSelector(IRecoveryAction.RecoveryAction_AccountNotServed.selector, _caller));
    vm.prank(_caller);
    _action.validateSig('', '', _calls);
  }

  /*///////////////////////////////////////////////////////////////
                            THE CALLER'S SHAPE
  ///////////////////////////////////////////////////////////////*/

  /// @notice A caller built as Ambire's 45-byte proxy over an implementation other than the pinned
  ///         one is refused, even for the batch its own attempt approves, since the action vouches
  ///         for one implementation's privilege rules only. The other implementation carries a copy
  ///         of the privilege-table mock at another address.
  function test_RevertWhen_AProxyOverAnotherImplementationAsks() external {
    address _otherImplementation = makeAddr('otherImplementation');
    vm.etch(_otherImplementation, _implementation.code);
    address _caller = makeAddr('otherProxyAccount');
    vm.etch(_caller, _servedProxyRuntime(_otherImplementation));
    // it should revert
    // it should name the caller
    _expectNotServedFor(_caller, true);
  }

  /// @notice A key that delegates by EIP-7702 to the pinned implementation is refused, since its
  ///         code is the designator, not the proxy, and the delegating key would keep signing after
  ///         the handover.
  function test_RevertWhen_AKeyDelegatingToTheServedImplementationAsks() external {
    address _caller = makeAddr('delegatingKey');
    vm.etch(_caller, ActionAmbireProxy.designator(_implementation));
    // it should revert
    // it should name the caller
    _expectNotServedFor(_caller, true);
  }

  /// @notice An address with no code that asks is refused, so no plain key can obtain an approval in
  ///         its own name.
  function test_RevertWhen_AnAddressWithNoCodeAsks() external {
    // it should revert
    // it should name the caller
    _expectNotServedFor(makeAddr('codelessCaller'), false);
  }

  /// @notice A contract that answers Ambire's privilege getter but is no proxy is refused, so
  ///         answering the getter is not what makes an account served.
  function test_RevertWhen_AContractThatIsNoProxyAsks() external {
    // it should revert
    // it should name the caller
    _expectNotServedFor(address(new ActionAmbireAccountMock()), true);
  }

  /// @notice The live account, rebuilt as a proxy over a second copy of Ambire's account code, is
  ///         sent its approved batch straight to execute and refuses it, because the action's answer
  ///         reverts inside the account, so no key moves and the attempt keeps waiting.
  function test_RevertWhen_TheLiveAccountIsAProxyOverAnotherImplementation() external {
    _buildLiveWorld();
    IPolicyManager.Attempt memory _attempt = _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    vm.etch(_live, _servedProxyRuntime(address(new ActionAmbireAccountFixture())));
    IAmbireRecoveryAction.Transaction[] memory _calls = _liveBatch(_attempt, address(0));
    bytes memory _signature = _kitSignature(address(_liveAction));
    // it should revert
    vm.expectRevert(abi.encodeWithSelector(IRecoveryAction.RecoveryAction_AccountNotServed.selector, _live));
    vm.prank(makeAddr('anyone'));
    IAmbireAccount(_live).execute(_calls, _signature);
    // it should leave every privilege and the attempt as they were
    assertEq(_livePrivilege(_newKey), bytes32(0), 'the new key holds nothing');
    assertEq(_livePrivilege(_removedKey), _SIGNER_VALUE, 'the removed key keeps its value');
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Waiting), 'the attempt still waits');
  }

  /*///////////////////////////////////////////////////////////////
                            THE COUNT
  ///////////////////////////////////////////////////////////////*/

  /// @notice A fourth call behind a three-call approval is refused at index 3 before any call is
  ///         read: the first call here is no consume, yet the refusal names the count, and the
  ///         privilege table is never read.
  function test_RevertWhen_AThreeCallOrderGetsFourCalls() external {
    vm.expectCall(address(_account), abi.encodeWithSelector(IAmbireAccount.privileges.selector), 0);
    // it should revert
    // it should name index 3 before reading any call
    _expectPlainRefusedAt(_junk(4), 3);
  }

  /// @notice An approved batch with one call added behind it is refused at the added call.
  function test_RevertWhen_ACallIsAddedBehindTheApprovedBatch() external {
    IAmbireRecoveryAction.Transaction[] memory _approved = _plainBatch();
    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](4);
    for (uint256 _i; _i < 3; ++_i) {
      _calls[_i] = _approved[_i];
    }
    _calls[3] = IAmbireRecoveryAction.Transaction({
      to: address(_account),
      value: 0,
      data: abi.encodeCall(IAmbireAccount.setAddrPrivilege, (makeAddr('x'), _KEY_VALUE))
    });
    // it should revert
    // it should name index 3
    _expectPlainRefusedAt(_calls, 3);
  }

  /// @notice A batch that drops the revoke is refused at index 2, the first index it lacks, so a
  ///         handover never adds a key without removing the lost one.
  function test_RevertWhen_AThreeCallOrderGetsTwoCalls() external {
    IAmbireRecoveryAction.Transaction[] memory _approved = _plainBatch();
    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](2);
    _calls[0] = _approved[0];
    _calls[1] = _approved[1];
    // it should revert
    // it should name index 2
    _expectPlainRefusedAt(_calls, 2);
  }

  /// @notice A batch carrying the consume alone is refused at index 1, so nothing is spent without
  ///         its writes.
  function test_RevertWhen_TheBatchCarriesTheConsumeAlone() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](1);
    _calls[0] = _plainBatch()[0];
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice An empty batch is refused at index 0.
  function test_RevertWhen_TheBatchIsEmpty() external {
    // it should revert
    // it should name index 0
    _expectPlainRefusedAt(_junk(0), 0);
  }

  /// @notice A token order's batch without its payment is refused at index 3, so the payee the
  ///         guardians approved is never skipped.
  function test_RevertWhen_AFourCallOrderGetsThreeCalls() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    // it should revert
    // it should name index 3
    _expectRefusal(_attempt, _plainBatch(), _notApproved(3));
  }

  /// @notice An order that names a token but no amount approves three calls, so a transfer of zero
  ///         to the payee riding behind them is refused at index 3 before any call is read.
  function test_RevertWhen_AnOrderNamingATokenButNoAmountGetsFourCalls() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(0);
    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](4);
    _calls[0] = _consumeCall(_manager, address(_action), _attempt.attemptId, _attempt.payloadHash);
    _calls[1] = _grantCall(address(_account), _newKey);
    _calls[2] = _revokeCall(address(_account), _removedKey);
    _calls[3] = IAmbireRecoveryAction.Transaction({
      to: _token, value: 0, data: abi.encodeWithSelector(_TRANSFER, _payee, uint256(0))
    });
    vm.expectCall(address(_account), abi.encodeWithSelector(IAmbireAccount.privileges.selector), 0);
    // it should revert
    // it should name index 3 before reading any call
    _expectRefusal(_attempt, _calls, _notApproved(3));
  }

  /// @notice A fifth call behind a four-call approval is refused at index 4 before any call is read.
  function test_RevertWhen_AFourCallOrderGetsFiveCalls() external {
    vm.expectCall(address(_account), abi.encodeWithSelector(IAmbireAccount.privileges.selector), 0);
    // it should revert
    // it should name index 4 before reading any call
    _expectRefusal(_tokenAttempt(10), _junk(5), _notApproved(4));
  }

  /// @notice Any count other than three, for an order with no amount, is refused at the first
  ///         index where the count differs, the smaller of the count and three, before any call is
  ///         read. `_lengthSeed` builds a count from 0 through 12 other than 3, of calls to the zero
  ///         address.
  function testFuzz_RevertWhen_TheCallCountIsNotTheApprovedOne(uint256 _lengthSeed) external {
    uint256 _length = bound(_lengthSeed, 0, 11);
    _length += _length < 3 ? 0 : 1;
    vm.expectCall(address(_account), abi.encodeWithSelector(IAmbireAccount.privileges.selector), 0);
    // it should revert
    _expectPlainRefusedAt(_junk(_length), _length < 3 ? _length : 3);
  }

  /// @notice The same for a four-call order, with counts from 0 through 12 other than 4.
  function testFuzz_RevertWhen_TheCallCountIsNotTheApprovedOneForAPayment(uint256 _lengthSeed) external {
    uint256 _length = bound(_lengthSeed, 0, 11);
    _length += _length < 4 ? 0 : 1;
    vm.expectCall(address(_account), abi.encodeWithSelector(IAmbireAccount.privileges.selector), 0);
    // it should revert
    _expectRefusal(_tokenAttempt(10), _junk(_length), _notApproved(_length < 4 ? _length : 4));
  }

  /*///////////////////////////////////////////////////////////////
                          THE CONSUME
  ///////////////////////////////////////////////////////////////*/

  /// @notice A consume sent to another address spends nothing at the manager, so it is refused.
  function test_RevertWhen_TheConsumeTargetsAnotherAddress() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[0].to = makeAddr('notTheManager');
    // it should revert
    // it should name index 0
    _expectPlainRefusedAt(_calls, 0);
  }

  /// @notice A consume carrying value is not the approved call.
  function test_RevertWhen_TheConsumeCarriesValue() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[0].value = 1;
    // it should revert
    // it should name index 0
    _expectPlainRefusedAt(_calls, 0);
  }

  /// @notice A consume naming another action spends another setup's attempt, so it is refused.
  function test_RevertWhen_TheConsumeNamesAnotherAction() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[0] = _consumeCall(_manager, makeAddr('otherAction'), _plain.attemptId, _plain.payloadHash);
    // it should revert
    // it should name index 0
    _expectPlainRefusedAt(_calls, 0);
  }

  /// @notice A consume naming another attempt id is refused.
  function test_RevertWhen_TheConsumeNamesAnotherAttemptId() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[0] = _consumeCall(_manager, address(_action), _plain.attemptId + 1, _plain.payloadHash);
    // it should revert
    // it should name index 0
    _expectPlainRefusedAt(_calls, 0);
  }

  /// @notice A consume naming another payload hash is refused.
  function test_RevertWhen_TheConsumeNamesAnotherPayloadHash() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[0] = _consumeCall(_manager, address(_action), _plain.attemptId, keccak256('another payload'));
    // it should revert
    // it should name index 0
    _expectPlainRefusedAt(_calls, 0);
  }

  /// @notice A consume with a byte trailing its arguments is not the approved call byte for byte.
  function test_RevertWhen_TheConsumeCarriesATrailingByte() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[0].data = abi.encodePacked(_calls[0].data, bytes1(0x00));
    // it should revert
    // it should name index 0
    _expectPlainRefusedAt(_calls, 0);
  }

  /// @notice Flipping any bits of any one byte of the consume's calldata is refused at index 0.
  ///         `_byteSeed` picks the byte and `_mask` is bounded to a nonzero flip.
  function testFuzz_RevertWhen_OneByteOfTheConsumeChanges(uint256 _byteSeed, uint256 _mask) external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    uint256 _at = bound(_byteSeed, 0, _calls[0].data.length - 1);
    _calls[0].data[_at] = bytes1(uint8(_calls[0].data[_at]) ^ uint8(bound(_mask, 1, 255)));
    // it should revert
    _expectPlainRefusedAt(_calls, 0);
  }

  /// @notice The consume moved behind the writes is refused at index 0, so the spend always runs
  ///         before the writes and the payment hands control to anyone.
  function test_RevertWhen_TheConsumeIsMovedBehindTheWrites() external {
    IAmbireRecoveryAction.Transaction[] memory _approved = _plainBatch();
    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](3);
    _calls[0] = _approved[1];
    _calls[1] = _approved[2];
    _calls[2] = _approved[0];
    // it should revert
    // it should name index 0
    _expectPlainRefusedAt(_calls, 0);
  }

  /*///////////////////////////////////////////////////////////////
                      THE GRANT AND THE REVOKE
  ///////////////////////////////////////////////////////////////*/

  /// @notice The grant and the revoke swapped rebuild another handover, so the refusal names the
  ///         grant's index.
  function test_RevertWhen_TheGrantAndTheRevokeAreSwapped() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    (_calls[1], _calls[2]) = (_calls[2], _calls[1]);
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A grant installing a key the guardians never approved is refused at index 1.
  function test_RevertWhen_TheGrantNamesAnotherNewKey() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1] = _grantCall(address(_account), makeAddr('attackerKey'));
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A revoke removing another key does not rebuild the approved handover either, and the
  ///         refusal names the grant's index.
  function test_RevertWhen_TheRevokeNamesAnotherRemovedKey() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _account.setPrivilege(makeAddr('otherKey'), _SIGNER_VALUE);
    _calls[2] = _revokeCall(address(_account), makeAddr('otherKey'));
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A payload with a byte trailing the two addresses opened the attempt. The batch names
  ///         its hash in the consume, but the grant and the revoke rebuild the canonical payload,
  ///         whose hash differs, so the refusal names the grant's index.
  function test_RevertWhen_ThePayloadCarriesATrailingByte() external {
    IPolicyManager.Attempt memory _attempt =
      _waiting(abi.encodePacked(_payload(_newKey, _removedKey), bytes1(0x00)), _noPayment());
    // it should revert
    // it should name index 1
    _expectRefusal(_attempt, _mockedBatch(_attempt, address(0)), _notApproved(1));
  }

  /// @notice A grant writing 2, the value that accepts a signature binding no account, is not the
  ///         approved grant.
  function test_RevertWhen_TheGrantWritesAnotherValue() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1].data = abi.encodeCall(IAmbireAccount.setAddrPrivilege, (_newKey, _SIGNER_VALUE));
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A grant writing a validator binding instead of a key is refused, so a handover that
  ///         passes every other check never installs code the account trusts.
  function test_RevertWhen_TheGrantWritesAValidatorBinding() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1].data = abi.encodeCall(
      IAmbireAccount.setAddrPrivilege, (_newKey, keccak256(abi.encode(makeAddr('validator'), bytes(''))))
    );
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice Any value other than 1 written for the new key is refused. `_value` is any word other
  ///         than 1.
  function testFuzz_RevertWhen_TheGrantWritesAnotherValue(uint256 _value) external {
    uint256 _other = bound(_value, 0, type(uint256).max - 1);
    _other += _other < 1 ? 0 : 1;
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1].data = abi.encodeCall(IAmbireAccount.setAddrPrivilege, (_newKey, bytes32(_other)));
    // it should revert
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A grant carrying value is not the approved grant.
  function test_RevertWhen_TheGrantCarriesValue() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1].value = 1;
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A grant sent to another address than the account is not the approved grant.
  function test_RevertWhen_TheGrantTargetsAnotherAddress() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1].to = makeAddr('otherTarget');
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A grant carrying the same arguments under another selector is not the approved grant.
  function test_RevertWhen_TheGrantUsesAnotherSelector() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1].data[0] = bytes1(uint8(_calls[1].data[0]) ^ 0x01);
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A grant with a byte trailing its arguments is not the approved grant byte for byte.
  function test_RevertWhen_TheGrantCarriesATrailingByte() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1].data = abi.encodePacked(_calls[1].data, bytes1(0x00));
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A grant too short to hold an address names no key, and is refused at index 1 rather
  ///         than failing without a named error.
  function test_RevertWhen_TheGrantIsTooShortToNameAnAddress() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[1].data = abi.encodePacked(IAmbireAccount.setAddrPrivilege.selector);
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A grant cut to its first 35 bytes, the selector and all but the last byte of the
  ///         address word, still names no full address, so it is refused at the grant's index. A
  ///         length check off by one byte would read past the call's data or accept a partial key.
  function test_RevertWhen_TheGrantStopsOneByteShortOfAnAddress() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    bytes memory _cut = new bytes(35);
    for (uint256 _i; _i < 35; ++_i) {
      _cut[_i] = _calls[1].data[_i];
    }
    _calls[1].data = _cut;
    // it should revert
    // it should name index 1
    _expectPlainRefusedAt(_calls, 1);
  }

  /// @notice A revoke writing a nonzero value leaves the lost key with power, so it is refused at
  ///         index 2. `_value` is any nonzero word.
  function testFuzz_RevertWhen_TheRevokeWritesAValue(uint256 _value) external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[2].data =
      abi.encodeCall(IAmbireAccount.setAddrPrivilege, (_removedKey, bytes32(bound(_value, 1, type(uint256).max))));
    // it should revert
    _expectPlainRefusedAt(_calls, 2);
  }

  /// @notice A revoke writing 1 leaves the lost key signing, so it is refused at index 2.
  function test_RevertWhen_TheRevokeWritesAValue() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[2].data = abi.encodeCall(IAmbireAccount.setAddrPrivilege, (_removedKey, _KEY_VALUE));
    // it should revert
    // it should name index 2
    _expectPlainRefusedAt(_calls, 2);
  }

  /// @notice A revoke carrying value is not the approved revoke.
  function test_RevertWhen_TheRevokeCarriesValue() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[2].value = 1;
    // it should revert
    // it should name index 2
    _expectPlainRefusedAt(_calls, 2);
  }

  /// @notice A revoke sent to another address than the account is not the approved revoke.
  function test_RevertWhen_TheRevokeTargetsAnotherAddress() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[2].to = makeAddr('otherTarget');
    // it should revert
    // it should name index 2
    _expectPlainRefusedAt(_calls, 2);
  }

  /// @notice A revoke carrying the same arguments under another selector is not the approved revoke.
  function test_RevertWhen_TheRevokeUsesAnotherSelector() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[2].data[0] = bytes1(uint8(_calls[2].data[0]) ^ 0x01);
    // it should revert
    // it should name index 2
    _expectPlainRefusedAt(_calls, 2);
  }

  /// @notice A revoke with a byte trailing its arguments is not the approved revoke byte for byte.
  function test_RevertWhen_TheRevokeCarriesATrailingByte() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[2].data = abi.encodePacked(_calls[2].data, bytes1(0x00));
    // it should revert
    // it should name index 2
    _expectPlainRefusedAt(_calls, 2);
  }

  /// @notice A revoke too short to hold an address names no key, so the batch is refused as not
  ///         approved. Which index the refusal names is left open here, since the revoke both
  ///         differs at its own index and fails to rebuild the payload.
  function test_RevertWhen_TheRevokeIsTooShortToNameAnAddress() external {
    IAmbireRecoveryAction.Transaction[] memory _calls = _plainBatch();
    _calls[2].data = abi.encodePacked(IAmbireAccount.setAddrPrivilege.selector);
    _mockAttempt(address(_account), _plain);
    // it should revert
    // it should raise BatchNotApproved
    vm.expectPartialRevert(IRecoveryAction.RecoveryAction_BatchNotApproved.selector);
    _ask(_calls);
  }

  /*///////////////////////////////////////////////////////////////
                    THE COMMITTED HANDOVER'S SHAPE
  ///////////////////////////////////////////////////////////////*/

  /// @notice An attempt committed to a handover whose new key is zero is refused with the rebuilt
  ///         payload, even through a batch that rebuilds it, since a direct call to the account
  ///         never passes through executeHandover's own refusal.
  function test_RevertWhen_TheCommittedNewKeyIsZero() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(address(0), _removedKey), _noPayment());
    IAmbireRecoveryAction.Transaction[] memory _calls =
      _approvedBatch(_manager, address(_action), address(_account), _attempt, address(0), _removedKey, address(0));
    // it should revert
    // it should carry the payload
    _expectRefusal(
      _attempt,
      _calls,
      abi.encodeWithSelector(
        IRecoveryAction.RecoveryAction_MalformedHandover.selector, _payload(address(0), _removedKey)
      )
    );
  }

  /// @notice An attempt committed to a handover whose removed key is zero is refused the same way.
  function test_RevertWhen_TheCommittedRemovedKeyIsZero() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, address(0)), _noPayment());
    IAmbireRecoveryAction.Transaction[] memory _calls =
      _approvedBatch(_manager, address(_action), address(_account), _attempt, _newKey, address(0), address(0));
    // it should revert
    // it should carry the payload
    _expectRefusal(
      _attempt,
      _calls,
      abi.encodeWithSelector(IRecoveryAction.RecoveryAction_MalformedHandover.selector, _payload(_newKey, address(0)))
    );
  }

  /// @notice An attempt committed to one address on both sides is refused, so the account never
  ///         ends a handover without the key it granted.
  function test_RevertWhen_TheCommittedKeysAreTheSameAddress() external {
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_removedKey, _removedKey), _noPayment());
    IAmbireRecoveryAction.Transaction[] memory _calls =
      _approvedBatch(_manager, address(_action), address(_account), _attempt, _removedKey, _removedKey, address(0));
    // it should revert
    // it should carry the payload
    _expectRefusal(
      _attempt,
      _calls,
      abi.encodeWithSelector(
        IRecoveryAction.RecoveryAction_MalformedHandover.selector, _payload(_removedKey, _removedKey)
      )
    );
  }

  /*///////////////////////////////////////////////////////////////
                        THE PRIVILEGE TABLE
  ///////////////////////////////////////////////////////////////*/

  /// @notice A new key that already holds the entry point's marker is refused naming it, so the
  ///         grant never overwrites code the account trusts.
  function test_RevertWhen_TheNewKeyAlreadyHoldsAPrivilege() external {
    _account.setPrivilege(_newKey, _ENTRY_POINT_MARKER);
    // it should revert
    // it should name the new key
    _expectRefusal(
      _plain, _plainBatch(), abi.encodeWithSelector(IRecoveryAction.RecoveryAction_AlreadyPrivileged.selector, _newKey)
    );
  }

  /// @notice Any nonzero entry on the new key, a key value included, is refused. `_value` is any
  ///         nonzero word.
  function testFuzz_RevertWhen_TheNewKeyAlreadyHoldsAPrivilege(uint256 _value) external {
    _account.setPrivilege(_newKey, bytes32(bound(_value, 1, type(uint256).max)));
    // it should revert
    _expectRefusal(
      _plain, _plainBatch(), abi.encodeWithSelector(IRecoveryAction.RecoveryAction_AlreadyPrivileged.selector, _newKey)
    );
  }

  /// @notice A removed key with an empty entry holds no key, so the handover would remove nothing
  ///         and is refused naming it.
  function test_RevertWhen_TheRemovedKeyHoldsNoKeyValue() external {
    _account.setPrivilege(_removedKey, bytes32(0));
    // it should revert
    // it should name the removed key
    _expectRefusal(
      _plain, _plainBatch(), abi.encodeWithSelector(IRecoveryAction.RecoveryAction_NotAKey.selector, _removedKey)
    );
  }

  /// @notice Any entry other than 1 or 2 on the removed address is code rather than a key, so it
  ///         is refused. `_value` is any word from 3 up.
  function testFuzz_RevertWhen_TheRemovedKeyHoldsNoKeyValue(uint256 _value) external {
    _account.setPrivilege(_removedKey, bytes32(bound(_value, 3, type(uint256).max)));
    // it should revert
    _expectRefusal(
      _plain, _plainBatch(), abi.encodeWithSelector(IRecoveryAction.RecoveryAction_NotAKey.selector, _removedKey)
    );
  }

  /// @notice A handover removing this action's own kit slot is refused, so a recovery can never
  ///         stop the account authorizing the action.
  function test_RevertWhen_TheRemovedEntryIsTheKitSlot() external {
    address _slot = _expectedKitSlot(address(_action));
    _account.setPrivilege(_slot, _expectedBinding(address(_action)));
    IPolicyManager.Attempt memory _attempt = _waiting(_payload(_newKey, _slot), _noPayment());
    IAmbireRecoveryAction.Transaction[] memory _calls =
      _approvedBatch(_manager, address(_action), address(_account), _attempt, _newKey, _slot, address(0));
    // it should revert
    // it should name the slot
    _expectRefusal(_attempt, _calls, abi.encodeWithSelector(IRecoveryAction.RecoveryAction_NotAKey.selector, _slot));
  }

  /*///////////////////////////////////////////////////////////////
                            THE PAYMENT
  ///////////////////////////////////////////////////////////////*/

  /// @notice A transfer in another token than the order's is refused at index 3.
  function test_RevertWhen_ThePaymentNamesAnotherToken() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    IPolicyManager.PaymentOrder memory _other = _orderCopy(_attempt.order);
    _other.token = makeAddr('otherToken');
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, _paymentCall(_other, _payee));
  }

  /// @notice A transfer of another amount than the order's is refused at index 3. `_amount` is any
  ///         amount other than the ordered 10.
  function testFuzz_RevertWhen_ThePaymentMovesAnotherAmount(uint256 _amount) external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    IPolicyManager.PaymentOrder memory _other = _orderCopy(_attempt.order);
    uint256 _moved = bound(_amount, 0, type(uint256).max - 1);
    _other.amount = _moved + (_moved < 10 ? 0 : 1);
    // it should revert
    _expectPaymentRefused(_attempt, _paymentCall(_other, _payee));
  }

  /// @notice A transfer to another payee than a fixed order names is refused, so nobody redirects
  ///         a payment the guardians approved.
  function test_RevertWhen_ThePaymentPaysAnotherPayee() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, _paymentCall(_attempt.order, makeAddr('thief')));
  }

  /// @notice A native payment standing where the order names a token is refused.
  function test_RevertWhen_ANativePaymentStandsWhereATokenIsOrdered() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, IAmbireRecoveryAction.Transaction({to: _payee, value: 10, data: ''}));
  }

  /// @notice A token transfer standing where the order names the native asset is refused.
  function test_RevertWhen_ATokenPaymentStandsWhereTheNativeAssetIsOrdered() external {
    IPolicyManager.Attempt memory _attempt = _nativeAttempt(10);
    // it should revert
    // it should name index 3
    _expectPaymentRefused(
      _attempt,
      IAmbireRecoveryAction.Transaction({
        to: _token, value: 0, data: abi.encodeWithSelector(_TRANSFER, _payee, uint256(10))
      })
    );
  }

  /// @notice A token transfer that also carries value is not the approved payment.
  function test_RevertWhen_TheTokenPaymentCarriesValue() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    IAmbireRecoveryAction.Transaction memory _payment = _paymentCall(_attempt.order, _payee);
    _payment.value = 1;
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, _payment);
  }

  /// @notice A transferFrom in place of the transfer is not the approved payment.
  function test_RevertWhen_ThePaymentIsATransferFrom() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    // it should revert
    // it should name index 3
    _expectPaymentRefused(
      _attempt,
      IAmbireRecoveryAction.Transaction({
        to: _token,
        value: 0,
        data: abi.encodeWithSignature('transferFrom(address,address,uint256)', address(_account), _payee, uint256(10))
      })
    );
  }

  /// @notice A native payment that carries data runs code at the payee, so it is refused.
  function test_RevertWhen_TheNativePaymentCarriesData() external {
    IPolicyManager.Attempt memory _attempt = _nativeAttempt(10);
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, IAmbireRecoveryAction.Transaction({to: _payee, value: 10, data: hex'00'}));
  }

  /// @notice A native payment of another amount is refused.
  function test_RevertWhen_TheNativePaymentSendsAnotherAmount() external {
    IPolicyManager.Attempt memory _attempt = _nativeAttempt(10);
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, IAmbireRecoveryAction.Transaction({to: _payee, value: 9, data: ''}));
  }

  /// @notice A native payment to another payee than a fixed order names is refused.
  function test_RevertWhen_TheNativePaymentPaysAnotherPayee() external {
    IPolicyManager.Attempt memory _attempt = _nativeAttempt(10);
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, IAmbireRecoveryAction.Transaction({to: makeAddr('thief'), value: 10, data: ''}));
  }

  /// @notice An open order frees the payee only: a transfer of another amount is still refused.
  function test_RevertWhen_AnOpenOrderPaymentMovesAnotherAmount() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    _attempt.order.payee = address(0);
    IPolicyManager.PaymentOrder memory _other = _orderCopy(_attempt.order);
    _other.amount = 11;
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, _paymentCall(_other, makeAddr('submitter')));
  }

  /// @notice An open order frees the payee only: a transfer in another token is still refused.
  function test_RevertWhen_AnOpenOrderPaymentNamesAnotherToken() external {
    IPolicyManager.Attempt memory _attempt = _tokenAttempt(10);
    _attempt.order.payee = address(0);
    IPolicyManager.PaymentOrder memory _other = _orderCopy(_attempt.order);
    _other.token = makeAddr('otherToken');
    // it should revert
    // it should name index 3
    _expectPaymentRefused(_attempt, _paymentCall(_other, makeAddr('submitter')));
  }

  /// @notice An open native order frees the payee only: another amount is still refused.
  function test_RevertWhen_AnOpenNativeOrderPaymentSendsAnotherAmount() external {
    IPolicyManager.Attempt memory _attempt = _nativeAttempt(10);
    _attempt.order.payee = address(0);
    // it should revert
    // it should name index 3
    IAmbireRecoveryAction.Transaction memory _payment =
      IAmbireRecoveryAction.Transaction({to: makeAddr('submitter'), value: 11, data: ''});
    _expectPaymentRefused(_attempt, _payment);
  }

  /*///////////////////////////////////////////////////////////////
                        THE LIVE ACCOUNT ASKS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The exact batch sent straight to the account's execute by anyone, with no
  ///         executeHandover frame, is approved and runs, since the callback is the whole check.
  function test_WhenTheLiveAccountIsSentTheApprovedBatchDirectly() external {
    _buildLiveWorld();
    IPolicyManager.Attempt memory _attempt = _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    vm.prank(makeAddr('anyone'));
    IAmbireAccount(_live).execute(_liveBatch(_attempt, address(0)), _kitSignature(address(_liveAction)));
    // it should run the batch
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
    assertEq(_livePrivilege(_newKey), _KEY_VALUE, 'new key installed');
    assertEq(_livePrivilege(_removedKey), bytes32(0), 'removed key zeroed');
  }

  /// @notice An open native order sent straight to the account with the zero address as its payee
  ///         is approved and runs the handover while paying nobody: the account skips a call to the
  ///         zero address, and the batch builder who chose it is the only party unpaid.
  function test_WhenALiveOpenNativeOrderIsSentWithTheZeroPayee() external {
    _buildLiveWorld();
    IPolicyManager.PaymentOrder memory _open =
      IPolicyManager.PaymentOrder({token: address(0), amount: 2 ether, payee: address(0)});
    IPolicyManager.Attempt memory _attempt = _plantLive(_payload(_newKey, _removedKey), _open, 0);
    uint256 _zeroBefore = address(0).balance;
    vm.prank(makeAddr('anyone'));
    IAmbireAccount(_live).execute(_liveBatch(_attempt, address(0)), _kitSignature(address(_liveAction)));
    // it should complete the handover and pay nobody
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
    assertEq(_livePrivilege(_newKey), _KEY_VALUE, 'new key installed');
    assertEq(_livePrivilege(_removedKey), bytes32(0), 'removed key zeroed');
    assertEq(_live.balance, 100 ether, 'the account paid nothing');
    assertEq(address(0).balance, _zeroBefore, 'nothing reached the zero address');
  }

  /// @notice Sending the same batch a second time reverts whole as a consumed attempt, and nothing
  ///         the first run wrote changes.
  function test_RevertWhen_TheSameBatchRunsASecondTimeThroughTheLiveAccount() external {
    _buildLiveWorld();
    IPolicyManager.Attempt memory _attempt = _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    IAmbireRecoveryAction.Transaction[] memory _calls = _liveBatch(_attempt, address(0));
    IAmbireAccount(_live).execute(_calls, _kitSignature(address(_liveAction)));
    _attempt.state = IPolicyManager.AttemptState.Consumed;
    // it should revert
    // it should refuse it as a consumed attempt
    vm.expectRevert(_notConsumable(_live, _attempt));
    IAmbireAccount(_live).execute(_calls, _kitSignature(address(_liveAction)));
    assertEq(_livePrivilege(_newKey), _KEY_VALUE, 'unchanged');
  }

  /// @notice The consume sent alone through the kit slot is refused, so the attempt keeps waiting
  ///         and nothing is spent without its writes.
  function test_RevertWhen_TheLiveAccountIsSentTheConsumeAlone() external {
    _buildLiveWorld();
    IPolicyManager.Attempt memory _attempt = _plantLive(_payload(_newKey, _removedKey), _noPayment(), 0);
    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](1);
    _calls[0] = _liveBatch(_attempt, address(0))[0];
    // it should revert
    // it should leave the attempt waiting
    vm.expectRevert(_notApproved(1));
    IAmbireAccount(_live).execute(_calls, _kitSignature(address(_liveAction)));
    assertEq(uint8(_liveState()), uint8(IPolicyManager.AttemptState.Waiting), 'still waiting');
  }
}
