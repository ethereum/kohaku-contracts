// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {Vm} from 'forge-std/Vm.sol';
import {IPolicyManager} from 'interfaces/IPolicyManager.sol';
import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';
import {PolicyManagerMockWritingMethod} from 'test/mocks/PolicyManagerMockWritingMethod.sol';
import {PolicyManagerAcceptanceTestBase} from 'test/utils/PolicyManagerAcceptanceTestBase.sol';

/// @notice consume, the spend: the account releases its own waiting attempt, exactly once, after
///         the wait its setup committed. It checks the attempt's state, its id, the setup nonce, the
///         wait and the payload hash against its own storage first, and only then asks each method
///         the accepted set used whether it vetoes, unless the setup committed to ignore stops. Only
///         a pause read answering exactly the encoding of true vetoes.
/// @dev The default rule is the base contract's: clause 0 needs place 0, clause 1 needs 2 of places
///      1, 2 and 3; method A judges places 0 and 1 and method B places 2 and 3. The default attempt
///      opens with places 0, 1 and 2, so it uses method A then method B, and waits one day. Both
///      methods are addresses whose code stops at once, so an unmocked pause read returns nothing.
contract PolicyManagerConsumeTest is PolicyManagerAcceptanceTestBase {
  /// @notice The wait of the default rule.
  uint48 internal constant _WAIT = 1 days;
  /// @notice The gas a call gets in the test of a huge answer. A manager that copies a huge answer
  ///         before reading its size runs out of it, and one that reads the size first does not.
  uint256 internal constant _HUGE_ANSWER_GAS = 2_000_000;
  /// @notice The size of a huge answer. Copying it into memory costs several million gas.
  uint256 internal constant _HUGE_ANSWER_SIZE = 2_000_000;

  /// @notice The block's timestamp when the default attempt opened.
  uint256 internal _openedAt;

  /*///////////////////////////////////////////////////////////////
                           NOTHING TO SPEND
  ///////////////////////////////////////////////////////////////*/

  /// @notice With no setup and no attempt ever recorded the spend is refused as
  ///         PolicyManager_NoActiveAttempt naming the caller and the action, and no method is asked.
  function test_WhenNoAttemptWasEverRecorded() external {
    _useDefaultRule(_WAIT, false);

    _expectNoMethodCalled();
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_NoActiveAttempt.selector, _account, _action));
    _consumeAsAccount(1, keccak256('payload'));
  }

  /// @notice A cancelled attempt is never released, even after its wait, and no method is asked.
  function test_WhenTheAttemptWasCancelled() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.prank(_account);
    _manager.cancelByOwner(_action, 1);
    vm.warp(_openedAt + _WAIT);

    _expectNoMethodCalled();
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_NoActiveAttempt.selector, _account, _action));
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice A new setup committed over a waiting attempt ends it, so after the wait the account
  ///         finds nothing to spend: no attempt outlives the setup it was judged under.
  function test_WhenANewSetupEndedTheAttempt() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    _commitRule();
    vm.warp(_openedAt + _WAIT);

    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_NoActiveAttempt.selector, _account, _action));
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice Clearing the setup ends a waiting attempt, so the clear alone turns the action off.
  function test_WhenAClearEndedTheAttempt() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    _clear(_account, _action);
    vm.warp(_openedAt + _WAIT);

    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_NoActiveAttempt.selector, _account, _action));
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice The spend reads the caller's own attempt, so an address other than the account finds
  ///         nothing to spend and the account's attempt keeps waiting. Only the account releases
  ///         its recovery. `_callerSeed` builds an address other than the account.
  function test_WhenAnotherAddressCalls(uint256 _callerSeed) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    address _caller = _addressFrom('caller', _callerSeed);

    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_NoActiveAttempt.selector, _caller, _action));
    vm.prank(_caller);
    _manager.consume(_action, 1, keccak256(_opening.payload));

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Waiting), 'waiting');
  }

  /// @notice An attempt waiting under one action is not spent through another action of the same
  ///         account: each action holds its own attempt.
  function test_WhenTheCallNamesAnotherAction() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);

    vm.expectRevert(
      abi.encodeWithSelector(IPolicyManager.PolicyManager_NoActiveAttempt.selector, _account, _otherAction)
    );
    vm.prank(_account);
    _manager.consume(_otherAction, 1, keccak256(_opening.payload));
  }

  /*///////////////////////////////////////////////////////////////
                           THE LOCAL CHECKS
  ///////////////////////////////////////////////////////////////*/

  /// @notice A spend naming any attempt id but the live one is refused as
  ///         PolicyManager_WrongAttemptId with both ids before any method is asked, so a spend aimed
  ///         at one attempt never releases another. `_offsetSeed` builds any id but the live one.
  function test_WhenTheAttemptIdIsNotTheLiveOne(uint64 _offsetSeed) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    uint64 _supplied = _otherThan(1, _offsetSeed);

    _expectNoMethodCalled();
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_WrongAttemptId.selector, _supplied, uint64(1)));
    _consumeAsAccount(_supplied, keccak256(_opening.payload));
  }

  /// @notice An attempt whose own setup nonce is not the stored one is refused as
  ///         PolicyManager_StaleAttempt with both nonces, before any method is asked. Every setup
  ///         write cancels the waiting attempt, so no sequence of calls leaves such a record and the
  ///         harness writes it: the check is a second guard against releasing a retired setup. The
  ///         record's method reports a stop, so asking it would change the error.
  function test_WhenTheAttemptWasJudgedUnderAnotherNonce() external {
    _useDefaultRule(_WAIT, false);
    uint64 _nonce = _commitRule();
    IPolicyManager.Attempt memory _record =
      _attempt(1, _nonce + 3, IPolicyManager.AttemptState.Waiting, false, _methods());
    _record.consumableAfter = uint48(block.timestamp);
    _plant(_account, _action, _record);

    vm.expectCall(_stoppedMethod, _pausedCall(), 0);
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_StaleAttempt.selector, _nonce + 3, _nonce));
    _consumeAsAccount(1, _record.payloadHash);
  }

  /// @notice Any time before the end of the wait the spend is refused as PolicyManager_WaitNotOver
  ///         carrying the block's timestamp and the end of the wait, and no method is asked.
  ///         `_elapsedSeed` picks how long after the opening the spend arrives, short of the wait.
  function test_WhenTheWaitIsNotOver(uint256 _elapsedSeed) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + bound(_elapsedSeed, 0, _WAIT - 1));

    _expectNoMethodCalled();
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyManager.PolicyManager_WaitNotOver.selector, uint48(block.timestamp), _endOfWait())
    );
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice One second before the end of the wait the spend is still refused: the whole wait must
  ///         pass.
  function test_WhenOneSecondOfTheWaitIsLeft() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT - 1);

    vm.expectRevert(
      abi.encodeWithSelector(IPolicyManager.PolicyManager_WaitNotOver.selector, uint48(block.timestamp), _endOfWait())
    );
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice A holder who committed a wait of zero can spend in the very block the attempt opened:
  ///         the kit enforces no minimum wait.
  function test_WhenTheWaitIsZero() external {
    _useDefaultRule(0, false);
    _commitRule();
    IPolicyManager.AttemptRequest memory _opening = _open(_places(0, 1, 2));

    _consumeAsAccount(1, keccak256(_opening.payload));

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
  }

  /// @notice Whatever wait the holder committed, the spend is refused one second before the wait has
  ///         passed since the set was accepted, so no wait can be cut short by a second. `_waitSeed`
  ///         picks a wait from one second to a hundred years.
  function test_WhenOneSecondOfAnyWaitIsLeft(uint256 _waitSeed) external {
    // casting to 'uint48' is safe because the wait is bound to a hundred years
    // forge-lint: disable-next-line(unsafe-typecast)
    uint48 _wait = uint48(bound(_waitSeed, 1, 100 * 365 days));
    _useDefaultRule(_wait, false);
    _commitRule();
    uint256 _end = block.timestamp + _wait;
    IPolicyManager.AttemptRequest memory _opening = _open(_places(0, 1, 2));

    vm.warp(_end - 1);
    vm.expectRevert(
      // casting to 'uint48' is safe because both times are at most a hundred years from the start
      // forge-lint: disable-next-line(unsafe-typecast)
      abi.encodeWithSelector(IPolicyManager.PolicyManager_WaitNotOver.selector, uint48(_end - 1), uint48(_end))
    );
    _consumeAsAccount(1, keccak256(_opening.payload));

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Waiting), 'waiting');
  }

  /// @notice Whatever wait the holder committed, the spend goes through at the exact second the wait
  ///         has passed since the set was accepted, so a recovery is never held past its wait.
  ///         `_waitSeed` picks a wait from one second to a hundred years.
  function test_WhenAnyWaitEndsThisSecond(uint256 _waitSeed) external {
    // casting to 'uint48' is safe because the wait is bound to a hundred years
    // forge-lint: disable-next-line(unsafe-typecast)
    uint48 _wait = uint48(bound(_waitSeed, 1, 100 * 365 days));
    _useDefaultRule(_wait, false);
    _commitRule();
    uint256 _end = block.timestamp + _wait;
    IPolicyManager.AttemptRequest memory _opening = _open(_places(0, 1, 2));

    vm.warp(_end);
    _consumeAsAccount(1, keccak256(_opening.payload));

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
  }

  /// @notice At a block timestamp past the uint48 width the spend reverts through the checked cast,
  ///         SafeCastOverflowedUintDowncast with the width and the timestamp, rather than comparing a
  ///         wrapped time with the end of the wait. `_nowSeed` picks a timestamp from 2^48 upward.
  function test_WhenTheBlockTimestampIsPastTheUint48Width(uint256 _nowSeed) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    uint256 _now = bound(_nowSeed, uint256(type(uint48).max) + 1, type(uint256).max);
    vm.warp(_now);

    vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(48), _now));
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice A spend naming any payload hash but the committed one is refused as
  ///         PolicyManager_WrongPayload with both hashes before any method is asked, so the account
  ///         releases only the outcome the guardians approved. `_maskSeed` flips at least one bit of the
  ///         committed hash.
  function test_WhenThePayloadHashIsNotTheCommittedOne(uint256 _maskSeed) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    bytes32 _committed = keccak256(_opening.payload);
    bytes32 _supplied = _committed ^ bytes32(bound(_maskSeed, 1, type(uint256).max));

    _expectNoMethodCalled();
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_WrongPayload.selector, _supplied, _committed));
    _consumeAsAccount(1, _supplied);
  }

  /*///////////////////////////////////////////////////////////////
                       THE ORDER OF THE CHECKS
  ///////////////////////////////////////////////////////////////*/

  /// @notice With no attempt waiting and the id, the nonce, the wait and the payload all wrong, the
  ///         missing attempt decides: the state is checked first. The ended record's method reports a
  ///         stop and is never asked.
  function test_WhenNoAttemptWaitsAndEveryOtherCheckFails() external {
    _useDefaultRule(_WAIT, false);
    uint64 _nonce = _commitRule();
    _plant(_account, _action, _attempt(1, _nonce + 3, IPolicyManager.AttemptState.Cancelled, false, _methods()));

    vm.expectCall(_stoppedMethod, _pausedCall(), 0);
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_NoActiveAttempt.selector, _account, _action));
    _consumeAsAccount(9, keccak256('another payload'));
  }

  /// @notice With the id, the nonce, the wait and the payload all wrong, the id decides: it is
  ///         checked right after the state.
  function test_WhenTheIdTheNonceTheWaitAndThePayloadAllFail() external {
    _useDefaultRule(_WAIT, false);
    uint64 _nonce = _commitRule();
    _plant(_account, _action, _attempt(1, _nonce + 3, IPolicyManager.AttemptState.Waiting, false, _methods()));

    vm.expectCall(_stoppedMethod, _pausedCall(), 0);
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_WrongAttemptId.selector, uint64(9), uint64(1)));
    _consumeAsAccount(9, keccak256('another payload'));
  }

  /// @notice With the nonce, the wait and the payload all wrong, the nonce decides: it is checked
  ///         before the wait.
  function test_WhenTheNonceTheWaitAndThePayloadAllFail() external {
    _useDefaultRule(_WAIT, false);
    uint64 _nonce = _commitRule();
    _plant(_account, _action, _attempt(1, _nonce + 3, IPolicyManager.AttemptState.Waiting, false, _methods()));

    vm.expectCall(_stoppedMethod, _pausedCall(), 0);
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_StaleAttempt.selector, _nonce + 3, _nonce));
    _consumeAsAccount(1, keccak256('another payload'));
  }

  /// @notice With the wait not over and the payload wrong, the wait decides: it is checked before
  ///         the payload. Both methods report a stop and neither is asked.
  function test_WhenTheWaitAndThePayloadBothFail() external {
    _openDefault();
    _stop(_methodA);
    _stop(_methodB);

    _expectNoMethodCalled();
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyManager.PolicyManager_WaitNotOver.selector, uint48(block.timestamp), _endOfWait())
    );
    _consumeAsAccount(1, keccak256('another payload'));
  }

  /// @notice With every other check passing, a wrong payload is refused before any method is
  ///         asked, even though a used method reports a stop: every local check runs before the
  ///         first outside call.
  function test_WhenThePayloadFailsAndAUsedMethodReportsAStop() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    _stop(_methodA);
    bytes32 _supplied = keccak256('another payload');

    vm.expectCall(_methodA, _pausedCall(), 0);
    vm.expectCall(_methodB, _pausedCall(), 0);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyManager.PolicyManager_WrongPayload.selector, _supplied, keccak256(_opening.payload))
    );
    _consumeAsAccount(1, _supplied);
  }

  /*///////////////////////////////////////////////////////////////
                               THE VETO
  ///////////////////////////////////////////////////////////////*/

  /// @notice When the first method the attempt used answers the pause read with exactly true, the
  ///         spend is refused as PolicyManager_MethodVetoedSpend naming it, and the attempt keeps
  ///         waiting: a method stopped during the wait stops the attempts it opened.
  function test_WhenTheFirstUsedMethodReportsAStop() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    _stop(_methodA);

    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_MethodVetoedSpend.selector, _methodA));
    _consumeAsAccount(1, keccak256(_opening.payload));

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Waiting), 'waiting');
  }

  /// @notice A stop on the second used method vetoes the spend as well, naming that method.
  function test_WhenOnlyTheSecondUsedMethodReportsAStop() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    _stop(_methodB);

    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_MethodVetoedSpend.selector, _methodB));
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice When every used method reports a stop, the veto names the first, in the order the
  ///         accepted proofs named the methods, and the second is never asked: the first veto ends
  ///         the spend.
  function test_WhenEveryUsedMethodReportsAStop() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    _stop(_methodA);
    _stop(_methodB);

    vm.expectCall(_methodB, _pausedCall(), 0);
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_MethodVetoedSpend.selector, _methodA));
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice A stopped method the rule names but the accepted set did not use has no say over the
  ///         spend and is never called: only the methods the set used can veto it. Method C judges
  ///         place 3, which the default attempt leaves empty.
  function test_WhenAMethodTheAttemptDidNotUseReportsAStop() external {
    address _methodC = _silentMethod('methodC');
    _useDefaultRule(_WAIT, false);
    _credentials[3].method = _methodC;
    _reshapeDefault(_WAIT, false);
    _commitRule();
    uint256 _acceptedAt = block.timestamp;
    IPolicyManager.AttemptRequest memory _opening = _open(_places(0, 1, 2));
    _stop(_methodC);
    vm.warp(_acceptedAt + _WAIT);

    vm.expectCall(_methodC, '', 0);
    _consumeAsAccount(1, keccak256(_opening.payload));

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
  }

  /// @notice A pause read that reverts is not a stop, so the spend goes through. `_revertData` is the
  ///         revert's data.
  function test_WhenThePauseReadReverts(bytes calldata _revertData) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.mockCallRevert(_methodB, _pausedCall(), _revertData);

    _spendAtTheEndOfTheWait(_opening);
  }

  /// @notice A pause read that reverts carrying exactly the encoding of true is not a stop either, so
  ///         a revert never passes for an answer.
  function test_WhenThePauseReadRevertsWithTrue() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.mockCallRevert(_methodB, _pausedCall(), abi.encode(true));

    _spendAtTheEndOfTheWait(_opening);
  }

  /// @notice A pause read that succeeds with nothing returned, the answer of a method that declares
  ///         no pause, is not a stop.
  function test_WhenThePauseReadReturnsNothing() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.mockCall(_methodB, _pausedCall(), '');

    _spendAtTheEndOfTheWait(_opening);
  }

  /// @notice A pause read returning fewer than 32 bytes is not a stop. `_lengthSeed` picks 1 to 31
  ///         bytes, the last of them 0x01.
  function test_WhenThePauseReadReturnsLessThanAWord(uint256 _lengthSeed) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    bytes memory _short = new bytes(bound(_lengthSeed, 1, 31));
    _short[_short.length - 1] = 0x01;
    vm.mockCall(_methodB, _pausedCall(), _short);

    _spendAtTheEndOfTheWait(_opening);
  }

  /// @notice A pause read returning one word other than the encoding of true is not a stop. `_seed`
  ///         builds the word: zero when it is 1, itself otherwise, so the word is never 1.
  function test_WhenThePauseReadReturnsAWordOtherThanTrue(uint256 _seed) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.mockCall(_methodB, _pausedCall(), abi.encode(_seed == 1 ? 0 : _seed));

    _spendAtTheEndOfTheWait(_opening);
  }

  /// @notice A pause read returning the encoding of true followed by more bytes is not a stop,
  ///         since only exactly one word counts. `_extra` is the trailing bytes after a first 0x01.
  function test_WhenThePauseReadReturnsTrueAndMore(bytes calldata _extra) external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.mockCall(_methodB, _pausedCall(), bytes.concat(abi.encode(true), hex'01', _extra));

    _spendAtTheEndOfTheWait(_opening);
  }

  /// @notice A pause answer of true followed by two megabytes is not a stop, and the manager reads
  ///         its size before copying it: the spend goes through on a gas budget that copying the
  ///         answer would exhaust.
  function test_WhenThePauseReadReturnsAHugeAnswer() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.mockCall(_methodB, _pausedCall(), bytes.concat(abi.encode(true), new bytes(_HUGE_ANSWER_SIZE)));
    vm.warp(_openedAt + _WAIT);

    vm.prank(_account);
    _manager.consume{gas: _HUGE_ANSWER_GAS}(_action, 1, keccak256(_opening.payload));

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
  }

  /// @notice A used method whose pause read writes its own storage cannot veto, since the read is a
  ///         static call and the write reverts it, and its storage stays untouched. Such a method
  ///         never passes a verify either, so the harness writes the spendable record naming it.
  function test_WhenThePauseReadWritesState() external {
    PolicyManagerMockWritingMethod _writer = new PolicyManagerMockWritingMethod();
    bytes32 _payloadHash = _plantSpendable(_methodList(address(_writer)));

    _consumeAsAccount(1, _payloadHash);

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
    assertEq(_writer.writes(), 0, 'the method wrote nothing');
  }

  /// @notice A used method at an address with no code answers the pause read with nothing, which is
  ///         not a stop. The harness writes the spendable record naming it.
  function test_WhenAUsedMethodHasNoCode() external {
    bytes32 _payloadHash = _plantSpendable(_methodList(address(0xDEAD0001)));

    _consumeAsAccount(1, _payloadHash);

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
  }

  /// @notice A holder who committed to ignore stops is spent through a stop on every used method,
  ///         and the manager asks no method at all: their choice, copied onto the attempt at
  ///         acceptance, reaches the spend.
  function test_WhenTheAttemptIgnoresStops() external {
    _useDefaultRule(_WAIT, true);
    _commitRule();
    uint256 _acceptedAt = block.timestamp;
    IPolicyManager.AttemptRequest memory _opening = _open(_places(0, 1, 2));
    _stop(_methodA);
    _stop(_methodB);
    vm.warp(_acceptedAt + _WAIT);

    _expectNoMethodCalled();
    _consumeAsAccount(1, keccak256(_opening.payload));

    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
  }

  /// @notice A stop refuses the spend while it is on and changes nothing else: once it lifts, the
  ///         same attempt is spent with the end of its wait unchanged, so a stop neither re-times
  ///         nor re-judges an accepted attempt.
  function test_WhenAStopLiftsBeforeTheSpend() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    uint48 _end = _state(_account, _action).attempt.consumableAfter;
    vm.warp(_openedAt + _WAIT);
    _stop(_methodB);
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_MethodVetoedSpend.selector, _methodB));
    _consumeAsAccount(1, keccak256(_opening.payload));

    vm.clearMockedCalls();
    _consumeAsAccount(1, keccak256(_opening.payload));

    IPolicyManager.Attempt memory _record = _state(_account, _action).attempt;
    assertEq(uint8(_record.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
    assertEq(_record.consumableAfter, _end, 'end of the wait unchanged');
  }

  /*///////////////////////////////////////////////////////////////
                              THE SPEND
  ///////////////////////////////////////////////////////////////*/

  /// @notice Once the wait is over and no used method vetoes, the account's spend turns the record
  ///         Consumed and keeps every other field, emits one AttemptConsumed naming the account, the
  ///         action and the attempt, asks each used method's pause exactly once by a static call and
  ///         nothing else, reads no proof, calls no account, and leaves the setup and the attempt
  ///         counter. The attempt is the second one under the first setup, id 2 under nonce 1, so the
  ///         event is seen to carry the id and not the nonce. `_delaySeed` picks how long after the
  ///         end of the wait the spend arrives, from zero.
  function test_WhenTheWaitIsOverAndNoUsedMethodVetoes(uint256 _delaySeed) external {
    _openDefault();
    vm.prank(_account);
    _manager.cancelByOwner(_action, 1);
    _openedAt = block.timestamp;
    IPolicyManager.AttemptRequest memory _opening = _open(_places(0, 1, 2));
    vm.warp(_openedAt + _WAIT + bound(_delaySeed, 0, 365 days));
    IPolicyManager.ActionState memory _before = _state(_account, _action);

    vm.expectCall(_methodA, _pausedCall(), 1);
    vm.expectCall(_methodB, _pausedCall(), 1);
    vm.expectCall(_methodA, abi.encodePacked(IPolicyMethod.verify.selector), 0);
    vm.expectCall(_methodB, abi.encodePacked(IPolicyMethod.verify.selector), 0);
    vm.expectCall(_account, '', 0);
    vm.recordLogs();
    vm.startStateDiffRecording();
    _consumeAsAccount(2, keccak256(_opening.payload));
    Vm.AccountAccess[] memory _accesses = vm.stopAndReturnStateDiff();
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    IPolicyManager.ActionState memory _after = _state(_account, _action);
    // it should set the attempt to Consumed and keep the rest of its record
    _assertRecordKept(_after.attempt, _before.attempt, IPolicyManager.AttemptState.Consumed);
    // it should emit AttemptConsumed alone
    assertEq(_logs.length, 1, 'one event');
    assertEq(_logs[0].emitter, address(_manager), 'AttemptConsumed emitter');
    assertEq(_logs[0].topics.length, 3, 'AttemptConsumed topics');
    assertEq(_logs[0].topics[0], IPolicyManager.AttemptConsumed.selector, 'AttemptConsumed topic0');
    assertEq(_logs[0].topics[1], bytes32(uint256(uint160(_account))), 'AttemptConsumed account');
    assertEq(_logs[0].topics[2], bytes32(uint256(uint160(_action))), 'AttemptConsumed action');
    assertEq(_logs[0].data, abi.encode(uint64(2)), 'AttemptConsumed data');
    // it should ask each used method once by a static call and call nothing else
    _assertOnlyStaticCalls(_accesses);
    // it should leave the setup and the attempt counter unchanged
    _assertSetupKept(_before, _after);
    assertEq(_after.nextAttemptId, _before.nextAttemptId, 'attempt counter');
  }

  /// @notice An attempt is released exactly once: the same spend sent again finds nothing waiting.
  function test_WhenTheSameSpendIsSentTwice() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    _consumeAsAccount(1, keccak256(_opening.payload));

    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_NoActiveAttempt.selector, _account, _action));
    _consumeAsAccount(1, keccak256(_opening.payload));
  }

  /// @notice A spent attempt frees the action's one slot: the next opening names the next id and
  ///         waits.
  function test_WhenAnAttemptOpensAfterTheSpend() external {
    IPolicyManager.AttemptRequest memory _opening = _openDefault();
    vm.warp(_openedAt + _WAIT);
    _consumeAsAccount(1, keccak256(_opening.payload));

    _open(_places(0, 1, 3));

    IPolicyManager.ActionState memory _after = _state(_account, _action);
    assertEq(_after.attempt.attemptId, 2, 'attempt id');
    assertEq(uint8(_after.attempt.state), uint8(IPolicyManager.AttemptState.Waiting), 'waiting');
  }

  /*///////////////////////////////////////////////////////////////
                                HELPERS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Commits the default rule with a one-day wait that honours stops, and opens attempt 1
  ///         with places 0, 1 and 2, noting the time it opened.
  function _openDefault() private returns (IPolicyManager.AttemptRequest memory _opening) {
    _useDefaultRule(_WAIT, false);
    _commitRule();
    _openedAt = block.timestamp;
    _opening = _open(_places(0, 1, 2));
  }

  /// @notice The end of the default attempt's wait: the time it opened plus the wait.
  function _endOfWait() private view returns (uint48 _end) {
    // casting to 'uint48' is safe because the test clock starts near zero and moves by days
    // forge-lint: disable-next-line(unsafe-typecast)
    _end = uint48(_openedAt + _WAIT);
  }

  /// @notice Sends consume for the default action as the account.
  function _consumeAsAccount(uint64 _attemptId, bytes32 _payloadHash) private {
    vm.prank(_account);
    _manager.consume(_action, _attemptId, _payloadHash);
  }

  /// @notice Moves to the end of the default attempt's wait, spends it as the account, and asserts
  ///         it now reads Consumed.
  function _spendAtTheEndOfTheWait(IPolicyManager.AttemptRequest memory _opening) private {
    vm.warp(_openedAt + _WAIT);
    _consumeAsAccount(1, keccak256(_opening.payload));
    assertEq(uint8(_state(_account, _action).attempt.state), uint8(IPolicyManager.AttemptState.Consumed), 'consumed');
  }

  /// @notice Commits the default rule and writes, through the harness, a waiting attempt 1 under the
  ///         stored nonce whose wait ends now and which used `_usedMethods`. Returns its payload hash.
  function _plantSpendable(address[] memory _usedMethods) private returns (bytes32 _payloadHash) {
    _useDefaultRule(_WAIT, false);
    uint64 _nonce = _commitRule();
    IPolicyManager.Attempt memory _record =
      _attempt(1, _nonce, IPolicyManager.AttemptState.Waiting, false, _usedMethods);
    _record.consumableAfter = uint48(block.timestamp);
    _plant(_account, _action, _record);
    _payloadHash = _record.payloadHash;
  }
}
