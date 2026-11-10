// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IPolicyManager} from 'interfaces/IPolicyManager.sol';
import {IRecoveryAction} from 'interfaces/IRecoveryAction.sol';

import {PolicyMethodRoles} from 'contracts/methods/roles/PolicyMethodRoles.sol';

import {IntegrationBase} from 'test/integration/base/IntegrationBase.sol';

/// @notice A bug in an identity method may be letting someone forge proofs. The holder's rule is any 3 of 4, one
///         credential per method: Ana's wallet (place 0), an Aadhaar guardian (place 1), a passport through zkPassport
///         (place 2) and Maya's passkey (place 3), with a five-day wait and stops on. The attacker stole Ana's key and
///         forges the two identity proofs. The pause holder, the deployment's Safe, stops the suspect method, the
///         spend is refused, anyone ends the attempt by veto, and the method is unpaused.
contract PauseStopsSuspectRecovery is IntegrationBase {
  /// @notice Local only: its rule names an identity credential, which no story can prove on a fork.
  function _runsOnForks() internal pure override returns (bool _runs) {
    _runs = false;
  }

  /// @notice The Aadhaar guardian's identity and the seed the holder's wallet asks proofs under.
  uint256 internal constant _AADHAAR_NULLIFIER = uint256(keccak256('Aadhaar guardian identity'));
  uint256 internal constant _AADHAAR_SEED = 12_345;

  /// @notice The holder's account.
  address internal _account;
  /// @notice The holder's rule, as the backup holds it.
  Rule internal _holderRule;

  function setUp() public override {
    super.setUp();
    _account = _openAccount(_originalKey.addr);
    Rule memory _r = _rule(
      _account,
      5 days,
      false,
      _thresholds(3),
      _sizes(4),
      _credentials(
        _walletGuardian(_ana),
        _aadhaarGuardian(_AADHAAR_NULLIFIER, _AADHAAR_SEED, 1 days),
        _passport(keccak256('holder passport chip')),
        _passkey(_mayaPasskey)
      )
    );
    _keep(_holderRule, _r);
    _setUpRecovery(_account, _originalKey, _r);
  }

  /*///////////////////////////////////////////////////////////////
                              THE WALK
  ///////////////////////////////////////////////////////////////*/

  /// @notice The stopped method is Aadhaar, the middle of the attempt's used methods (wallet, Aadhaar, zkPassport). The
  ///         spend is refused even though the first used method, the wallet method, has no stop, then anyone ends the
  ///         attempt by veto, and it stays ended after the unpause. The holder keeps the account although the forged
  ///         proofs once satisfied the rule.
  function test_WhenTheStoppedMethodIsTheMiddleOfTheUsedMethods() external {
    _stopRefusesTheSpendAndAVetoEndsIt(address(_aadhaarMethod));
  }

  /// @notice The same story with zkPassport stopped, the last of the attempt's used methods.
  function test_WhenTheStoppedMethodIsTheLastUsedMethod() external {
    _stopRefusesTheSpendAndAVetoEndsIt(address(_zkPassportMethod));
  }

  /// @notice The attacker opens, the stop refuses the spend after the wait, nobody vetoes, and the pause holder
  ///         unpauses the method. The account is the attacker's in the block after the unpause, with no notice window
  ///         left: a stop refuses the spend, and only a veto ends the attempt.
  function test_WhenNobodyVetoesBeforeTheUnpause() external {
    // The attacker opens the attempt, and the pause holder stops the Aadhaar method.
    bytes memory _payload = _attackerOpens();
    _pauseHolderStops(address(_aadhaarMethod));

    // The wait passes, and the attacker's execute reverts.
    skip(5 days);
    vm.prank(_attacker.addr);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyManager.PolicyManager_MethodVetoedSpend.selector, address(_aadhaarMethod))
    );
    _action.executeHandover(_account, _payload);

    // The pause holder unpauses the method, and nobody sent cancelByVeto.
    _pauseHolderUnpauses(address(_aadhaarMethod));

    // In the next block the attacker sends executeHandover, and the account is theirs.
    vm.roll(block.number + 1);
    _executes(_attacker.addr, _account, _payload);
    _assertKeyControls(_account, _attacker, 'the attacker');
    _assertKeyLocked(_account, _originalKey);
  }

  /*///////////////////////////////////////////////////////////////
                              EVEN IF
  ///////////////////////////////////////////////////////////////*/

  /// @notice A veto sent during the wait, two days after the opening, works too, since a veto needs no wait.
  function test_WhenTheVetoComesDuringTheWait() external {
    // The attacker opens the attempt, and the pause holder stops the Aadhaar method.
    bytes memory _payload = _attackerOpens();
    _pauseHolderStops(address(_aadhaarMethod));

    // Two days into the wait, a friend sends cancelByVeto naming the Aadhaar method.
    skip(2 days);
    _vetoes(_friend, 1, address(_aadhaarMethod));
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Cancelled), 'the veto ended it');

    // The method is unpaused, the wait passes, and the attacker's handover runs nowhere.
    _pauseHolderUnpauses(address(_aadhaarMethod));
    skip(3 days);
    vm.prank(_attacker.addr);
    vm.expectPartialRevert(IRecoveryAction.RecoveryAction_NotConsumable.selector);
    _action.executeHandover(_account, _payload);
    _assertKeyControls(_account, _originalKey, 'the holder key');
  }

  /// @notice With the Aadhaar method stopped, a request that leans on its place is refused, and one that leaves the
  ///         place out and fills the clause with the other methods opens and executes through the stop. The stop
  ///         reaches the proofs of the stopped method, not the whole rule.
  function test_WhenARequestLeavesTheStoppedMethodOut() external {
    Rule memory _r = _holderRule;
    // The pause holder stops the Aadhaar method.
    _pauseHolderStops(address(_aadhaarMethod));

    // Ana, the Aadhaar guardian and Maya's passkey approve a handover to the new key, and the opening is refused.
    IPolicyManager.AttemptRequest memory _withAadhaar = _request(
      _account, _r, _handover(_newKey.addr, _originalKey.addr), _noPayment(), uint48(block.timestamp + 24 hours)
    );
    _signApproval(_withAadhaar, _r, 0);
    _signApproval(_withAadhaar, _r, 1);
    _signApproval(_withAadhaar, _r, 3);
    vm.prank(_friend);
    vm.expectPartialRevert(IPolicyManager.PolicyManager_MethodStopped.selector);
    _manager.startAttempt(_withAadhaar);

    // Ana, the passport holder and Maya's passkey approve instead, leaving the Aadhaar place out, and it opens.
    bytes memory _payload = _approversOpen(_places(0, 2, 3));

    // The wait passes with the stop still on, and the handover hands the account to the new key.
    skip(5 days);
    _executes(_executor, _account, _payload);
    _assertKeyControls(_account, _newKey, 'the new key');
  }

  /*///////////////////////////////////////////////////////////////
                             TRADE-OFFS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The veto cannot tell a wanted attempt from a forged one: Maya's own recovery is ended too, and her
  ///         approvers sign again after the unpause, since their first approvals named attempt 1.
  function test_WhenTheStopEndsTheHoldersOwnAttempt() external {
    // Ana, the Aadhaar guardian and Maya's passkey open attempt 1 to the new key.
    _approversOpen(_places(0, 1, 3));

    // The pause holder stops the Aadhaar method, anyone vetoes attempt 1, and the method is unpaused.
    _pauseHolderStops(address(_aadhaarMethod));
    _vetoes(makeAddr('someone else'), 1, address(_aadhaarMethod));
    _pauseHolderUnpauses(address(_aadhaarMethod));
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Cancelled), 'Maya attempt ended');

    // The approvers sign again for attempt 2, it opens, the wait passes and the handover runs.
    bytes memory _payload = _approversOpen(_places(0, 1, 3));
    skip(5 days);
    _executes(_executor, _account, _payload);
    _assertKeyControls(_account, _newKey, 'the new key');
  }

  /// @notice The pause holder can aim a stop, a veto and an unpause at one holder's attempt while another holder's
  ///         attempt over the same method waits through it. A submitter who adds an extra Aadhaar place to a request
  ///         that did not need it exposes that attempt to the aim.
  function test_WhenThePauseHolderTargetsOneAttempt() external {
    // Lena set up recovery on her own account with any 2 of Carla's wallet and her own Aadhaar guardian.
    Person memory _lena = _person('Lena key');
    Person memory _lenaNewKey = _person('Lena new key');
    address _lenaAccount = _openAccount(_lena.addr);
    Rule memory _lenaRule = _rule(
      _lenaAccount,
      5 days,
      false,
      _thresholds(2),
      _sizes(2),
      _credentials(_walletGuardian(_carla), _aadhaarGuardian(uint256(keccak256('Lena Aadhaar guardian')), 777, 1 days))
    );
    _setUpRecovery(_lenaAccount, _lena, _lenaRule);

    // Maya's four approvers all sign, and the submitter sends all four places, the Aadhaar one an extra.
    bytes memory _mayaPayload = _approversOpen(_fourPlaces());

    // Lena's approvers open her handover to her new key.
    bytes memory _lenaPayload = _handover(_lenaNewKey.addr, _lena.addr);
    IPolicyManager.AttemptRequest memory _lenaReq =
      _request(_lenaAccount, _lenaRule, _lenaPayload, _noPayment(), uint48(block.timestamp + 24 hours));
    _signApproval(_lenaReq, _lenaRule, 0);
    _signApproval(_lenaReq, _lenaRule, 1);
    _submits(_friend, _lenaReq);

    // The pause holder stops the Aadhaar method, vetoes only Maya's attempt, and unpauses the method.
    _pauseHolderStops(address(_aadhaarMethod));
    _vetoes(_identitySafe, 1, address(_aadhaarMethod));
    _pauseHolderUnpauses(address(_aadhaarMethod));

    // The wait passes: Lena's handover runs, and Maya's is refused.
    skip(5 days);
    _executes(_executor, _lenaAccount, _lenaPayload);
    _assertKeyControls(_lenaAccount, _lenaNewKey, 'Lena new key');
    vm.prank(_executor);
    vm.expectPartialRevert(IRecoveryAction.RecoveryAction_NotConsumable.selector);
    _action.executeHandover(_account, _mayaPayload);
    assertEq(_privilegeOf(_account, _newKey.addr), bytes32(0), 'the new key was not installed on Maya account');
  }

  /// @notice Maya's four approvers all sign, and a front-runner submits only places 0, 2 and 3, which satisfy the rule
  ///         without the Aadhaar proof. The attempt's used methods are then the wallet, zkPassport and passkey ones, so
  ///         the pause holder of zkPassport, a method the subset used, can stop it and end the attempt by veto.
  function test_WhenAFrontRunnerSubmitsASubsetAndAUsedMethodIsStopped() external {
    // The front-runner opens with a subset of the gathered proofs.
    bytes memory _payload = _frontRunnerOpensWithoutTheAadhaarPlace();

    // The pause holder stops zkPassport, which the subset used, and vetoes the attempt.
    _pauseHolderStops(address(_zkPassportMethod));
    _vetoes(_identitySafe, 1, address(_zkPassportMethod));
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Cancelled), 'the veto ended it');

    // The wait passes and the handover runs nowhere.
    skip(5 days);
    vm.prank(_executor);
    vm.expectPartialRevert(IRecoveryAction.RecoveryAction_NotConsumable.selector);
    _action.executeHandover(_account, _payload);
    _assertKeyControls(_account, _originalKey, 'the holder key');
  }

  /// @notice Maya's four approvers all sign, and a front-runner submits only places 0, 2 and 3. The rule names the
  ///         Aadhaar method, but the subset did not use it, so a veto naming it is refused with MethodNotUsed even
  ///         while it is stopped: the front-runner chose which methods can veto this attempt.
  function test_WhenAFrontRunnerSubmitsASubsetAndAnUnusedMethodIsStopped() external {
    // The front-runner opens with a subset of the gathered proofs.
    _frontRunnerOpensWithoutTheAadhaarPlace();

    // The pause holder stops the Aadhaar method and names it in a veto. It fails.
    _pauseHolderStops(address(_aadhaarMethod));
    vm.prank(_identitySafe);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyManager.PolicyManager_MethodNotUsed.selector, uint64(1), address(_aadhaarMethod))
    );
    _manager.cancelByVeto(_account, address(_action), 1, address(_aadhaarMethod));
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Waiting), 'the attempt still waits');
  }

  /// @notice Maya lost her key and Ana does not answer, so her clause needs the Aadhaar guardian: she waits for the
  ///         unpause, then recovers. A pause holder who is compromised, or renounces while stopped, can strand a holder
  ///         for good.
  function test_WhenAKeylessHolderWaitsForTheUnpause() external {
    Rule memory _r = _holderRule;
    // The pause holder stops the Aadhaar method, and Maya's request leaning on it is refused.
    _pauseHolderStops(address(_aadhaarMethod));
    IPolicyManager.AttemptRequest memory _req = _request(
      _account, _r, _handover(_newKey.addr, _originalKey.addr), _noPayment(), uint48(block.timestamp + 24 hours)
    );
    _signApproval(_req, _r, 1);
    _signApproval(_req, _r, 2);
    _signApproval(_req, _r, 3);
    vm.prank(_friend);
    vm.expectPartialRevert(IPolicyManager.PolicyManager_MethodStopped.selector);
    _manager.startAttempt(_req);

    // Ten days later the method is unpaused, and the same approvers recover the account.
    skip(10 days);
    _pauseHolderUnpauses(address(_aadhaarMethod));
    bytes memory _payload = _approversOpen(_places(1, 2, 3));
    skip(5 days);
    _executes(_executor, _account, _payload);
    _assertKeyControls(_account, _newKey, 'the new key');

    // Elsewhere, a thief who took the pause holder's Safe strands a passport holder for good.
    _aThiefWithThePauseRoleStrandsAPassportHolder();
  }

  /*///////////////////////////////////////////////////////////////
                              UTILITIES
  ///////////////////////////////////////////////////////////////*/

  /// @notice The walk for one stopped method among the attempt's used methods.
  function _stopRefusesTheSpendAndAVetoEndsIt(address _stopped) internal {
    // The attacker sends startAttempt with places 0, 1 and 2, handing the account to their own key.
    bytes memory _payload = _attackerOpens();

    // The pause holder sends pause() on the suspect method.
    _pauseHolderStops(_stopped);

    // The wait passes, and the attacker sends executeHandover. It reverts, since the stopped method vetoes the spend.
    skip(5 days);
    vm.prank(_attacker.addr);
    vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyManager_MethodVetoedSpend.selector, _stopped));
    _action.executeHandover(_account, _payload);

    // The first used method, the wallet method, has no stop: naming it in a veto fails.
    vm.prank(_friend);
    vm.expectPartialRevert(IPolicyManager.PolicyManager_MethodNotStopped.selector);
    _manager.cancelByVeto(_account, address(_action), 1, address(_ecdsaMethod));

    // Anyone sends cancelByVeto naming attempt 1 and the stopped method.
    _vetoes(_friend, 1, _stopped);

    // The pause holder sends unpause().
    _pauseHolderUnpauses(_stopped);

    // The attempt stays cancelled after the unpause, and the attacker's handover runs nowhere.
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Cancelled), 'attempt 1 is cancelled');
    vm.prank(_attacker.addr);
    vm.expectPartialRevert(IRecoveryAction.RecoveryAction_NotConsumable.selector);
    _action.executeHandover(_account, _payload);

    // The account is unchanged.
    assertEq(_privilegeOf(_account, _attacker.addr), bytes32(0), 'the attacker holds nothing');
    _assertKeyControls(_account, _originalKey, 'the holder key');
  }

  /// @notice Diana's rule is her passport alone. A thief who took the pause holder's Safe stops zkPassport and
  ///         renounces the role: nobody can unpause the method, and Diana can never open her recovery.
  function _aThiefWithThePauseRoleStrandsAPassportHolder() internal {
    // Diana sets up recovery, and the thief stops zkPassport and renounces the role.
    Person memory _diana = _person('Diana key');
    address _dianaAccount = _openAccount(_diana.addr);
    Rule memory _dianaRule = _rule(
      _dianaAccount, 48 hours, false, _thresholds(1), _sizes(1), _credentials(_passport(keccak256('Diana passport')))
    );
    _setUpRecovery(_dianaAccount, _diana, _dianaRule);
    _pauseHolderStops(address(_zkPassportMethod));
    vm.prank(_identitySafe);
    PolicyMethodRoles(address(_zkPassportMethod)).renounceOwnership();

    // Nobody can unpause the method any more.
    vm.prank(_identitySafe);
    vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
    PolicyMethodRoles(address(_zkPassportMethod)).unpause();

    // A year later Diana, keyless, proves her passport, and her opening is still refused.
    skip(365 days);
    IPolicyManager.AttemptRequest memory _dianaReq = _request(
      _dianaAccount, _dianaRule, _handover(_newKey.addr, _diana.addr), _noPayment(), uint48(block.timestamp + 24 hours)
    );
    _signApproval(_dianaReq, _dianaRule, 0);
    vm.prank(_friend);
    vm.expectPartialRevert(IPolicyManager.PolicyManager_MethodStopped.selector);
    _manager.startAttempt(_dianaReq);
    assertEq(_privilegeOf(_dianaAccount, _newKey.addr), bytes32(0), 'Diana is stranded');
  }

  /// @notice The attacker signs place 0 with Ana's stolen key and forges the Aadhaar proof for place 1 and the passport
  ///         proof for place 2, then submits. The local verifier stand-ins accept any well-formed proof, so producing
  ///         the proof from a credential's config stands for the method bug the stop is for.
  function _attackerOpens() internal returns (bytes memory _payload) {
    Rule memory _r = _holderRule;
    _payload = _handover(_attacker.addr, _originalKey.addr);
    IPolicyManager.AttemptRequest memory _req =
      _request(_account, _r, _payload, _noPayment(), uint48(block.timestamp + 24 hours));
    _signApproval(_req, _r, 0);
    _signApproval(_req, _r, 1);
    _signApproval(_req, _r, 2);
    _submits(_attacker.addr, _req);
  }

  /// @notice The holder's approvers at the given places approve a handover to the new key, and a friend submits.
  function _approversOpen(uint256[] memory _filled) internal returns (bytes memory _payload) {
    Rule memory _r = _holderRule;
    _payload = _handover(_newKey.addr, _originalKey.addr);
    IPolicyManager.AttemptRequest memory _req =
      _request(_account, _r, _payload, _noPayment(), uint48(block.timestamp + 24 hours));
    for (uint256 _i; _i < _filled.length; ++_i) {
      _signApproval(_req, _r, _filled[_i]);
    }
    _submits(_friend, _req);
  }

  /// @notice Ana, the Aadhaar guardian, the passport holder and Maya's passkey all approve a handover to the new key,
  ///         and a front-runner who saw the gathered proofs submits only places 0, 2 and 3, leaving the Aadhaar proof
  ///         out. Each proof signs its own place's digest, so dropping one leaves the others valid.
  function _frontRunnerOpensWithoutTheAadhaarPlace() internal returns (bytes memory _payload) {
    Rule memory _r = _holderRule;
    _payload = _handover(_newKey.addr, _originalKey.addr);
    IPolicyManager.AttemptRequest memory _gathered =
      _request(_account, _r, _payload, _noPayment(), uint48(block.timestamp + 24 hours));
    _signApproval(_gathered, _r, 0);
    _signApproval(_gathered, _r, 1);
    _signApproval(_gathered, _r, 2);
    _signApproval(_gathered, _r, 3);

    IPolicyManager.AttemptRequest memory _subset = _copy(_gathered);
    _subset.proofs = new IPolicyManager.ProofPlace[](3);
    (_subset.proofs[0], _subset.proofs[1], _subset.proofs[2]) =
    (_gathered.proofs[0], _gathered.proofs[2], _gathered.proofs[3]);
    _submits(makeAddr('front-runner'), _subset);
    assertEq(uint8(_attempt(_account).state), uint8(IPolicyManager.AttemptState.Waiting), 'the subset opened');
  }

  /// @notice The pause holder stops a method.
  function _pauseHolderStops(address _method) internal {
    vm.prank(_identitySafe);
    PolicyMethodRoles(_method).pause();
  }

  /// @notice The pause holder unpauses a method.
  function _pauseHolderUnpauses(address _method) internal {
    vm.prank(_identitySafe);
    PolicyMethodRoles(_method).unpause();
  }

  /// @notice Someone ends the holder's attempt by naming a stopped method.
  function _vetoes(address _caller, uint64 _attemptId, address _method) internal {
    vm.prank(_caller);
    _manager.cancelByVeto(_account, address(_action), _attemptId, _method);
  }

  /// @notice A list of three places.
  function _places(uint256 _a, uint256 _b, uint256 _c) internal pure returns (uint256[] memory _p) {
    _p = new uint256[](3);
    (_p[0], _p[1], _p[2]) = (_a, _b, _c);
  }

  /// @notice All four places.
  function _fourPlaces() internal pure returns (uint256[] memory _p) {
    _p = new uint256[](4);
    (_p[0], _p[1], _p[2], _p[3]) = (0, 1, 2, 3);
  }
}
