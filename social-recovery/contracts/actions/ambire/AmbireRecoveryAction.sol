// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {IPolicyAction} from 'interfaces/IPolicyAction.sol';
import {IPolicyManager} from 'interfaces/IPolicyManager.sol';
import {IRecoveryAction} from 'interfaces/IRecoveryAction.sol';

import {IAmbireAccount} from 'contracts/actions/ambire/IAmbireAccount.sol';
import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';

/// @title AmbireRecoveryAction
/// @author defi-wonderland
/// @notice The recovery action for Ambire's AmbireAccount. It performs one key handover for
///         each approved attempt. The account authorizes it through one privilege entry
///         under KIT_SLOT.
/// @dev The action stores nothing and has no owner, so nobody can stop it. The account binds
///      this action as a validator by writing BINDING under KIT_SLOT. Before the account runs
///      a batch sent under that slot, it asks this action through validateSig.
contract AmbireRecoveryAction is IAmbireRecoveryAction {
  /*///////////////////////////////////////////////////////////////
                          STATE VARIABLES
  ///////////////////////////////////////////////////////////////*/

  /// @inheritdoc IAmbireRecoveryAction
  bytes32 public constant KEY_VALUE = bytes32(uint256(1));

  /// @notice The account's other key value, 2.
  /// @dev isAuthority uses it to recognize a key written at 2, such as the signer key that
  ///      Ambire's factory creates at 2. A key at 2 also passes a plain signature that names no
  ///      account, so the grant never writes this value.
  bytes32 private constant _RESERVED_KEY_VALUE = bytes32(uint256(2));

  /// @notice The first nine bytes of the minimal proxy that Ambire's factory deploys.
  bytes9 private constant _PROXY_PREFIX = 0x363d3d373d3d3d363d;

  /// @notice The tenth byte of the minimal proxy: the opcode PUSH20, which pushes the twenty
  ///         bytes of the implementation address that follow it.
  bytes1 private constant _PUSH20 = 0x73;

  /// @notice The last fifteen bytes of the minimal proxy, after the implementation address.
  bytes15 private constant _PROXY_SUFFIX = 0x5af43d82803e903d91602b57fd5bf3;

  /// @notice The last byte of the signature handed to the account's execute, which tells the
  ///         account to ask the validator bound under the slot the signature names.
  uint8 private constant _VALIDATOR_SIGNATURE_MODE = 255;

  /// @notice The number of calls in a batch when the order has no amount. The batch is always
  ///         these three calls: the consume, the grant and the revoke.
  uint256 private constant _CALLS_WITHOUT_PAYMENT = 3;

  /// @notice The number of calls in a batch when the order has an amount. The payment is added
  ///         as a fourth call, after the consume, the grant and the revoke.
  uint256 private constant _CALLS_WITH_PAYMENT = 4;

  /// @notice The position of the consume call in the batch.
  uint256 private constant _CONSUME_INDEX = 0;

  /// @notice The position of the grant of the new key in the batch.
  uint256 private constant _GRANT_INDEX = 1;

  /// @notice The position of the revoke of the removed key in the batch.
  uint256 private constant _REVOKE_INDEX = 2;

  /// @notice The position of the payment in the batch. The batch has a payment only when the order
  ///         has an amount.
  uint256 private constant _PAYMENT_INDEX = 3;

  /// @inheritdoc IAmbireRecoveryAction
  IPolicyManager public immutable MANAGER;

  /// @inheritdoc IAmbireRecoveryAction
  address public immutable AMBIRE_IMPLEMENTATION;

  /// @inheritdoc IAmbireRecoveryAction
  address public immutable KIT_SLOT;

  /// @inheritdoc IAmbireRecoveryAction
  bytes32 public immutable BINDING;

  /// @notice The code hash of the one proxy this action serves: the 45-byte minimal proxy that
  ///         pushes AMBIRE_IMPLEMENTATION at its full twenty bytes.
  /// @dev The constructor hashes _PROXY_PREFIX, _PUSH20, AMBIRE_IMPLEMENTATION and
  ///      _PROXY_SUFFIX, the 45 bytes of the proxy in that order. supportsAccount,
  ///      executeHandover and validateSig compare the result with the account's code hash.
  bytes32 private immutable _PROXY_CODEHASH;

  /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ///////////////////////////////////////////////////////////////*/

  /// @notice Deploys the action for one manager and one AmbireAccount implementation.
  /// @param _manager The policy manager whose attempts this action spends.
  /// @param _ambireImplementation The pinned AmbireAccount implementation this action serves.
  constructor(IPolicyManager _manager, address _ambireImplementation) {
    MANAGER = _manager;
    AMBIRE_IMPLEMENTATION = _ambireImplementation;
    KIT_SLOT = address(uint160(uint256(keccak256(abi.encode('kit', address(this))))));
    BINDING = keccak256(abi.encode(address(this), bytes('')));
    _PROXY_CODEHASH = keccak256(abi.encodePacked(_PROXY_PREFIX, _PUSH20, _ambireImplementation, _PROXY_SUFFIX));
  }

  /*///////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRecoveryAction
  /// @dev The checks run in this order. First the account fit: the account's code must be the one
  ///      proxy this action serves, before the manager is read. Writing the slot entry tells this
  ///      action nothing, so a setup can exist on an account it does not serve, and an account whose
  ///      fallback accepts any call would never call validateSig. This check is what stops such a
  ///      call from returning as if the handover ran. Second, the manager's attempt for the account
  ///      must be spendable: waiting, with its wait over. Third, the payload's hash must equal the
  ///      attempt's payload hash. These three early checks only fail fast and save the caller gas.
  ///      The authorization itself is enforced later, inside the account: the account calls
  ///      validateSig before it runs the batch, and the batch's first call is the manager's
  ///      consume, which spends the attempt only when it is spendable for this payload. Fourth, the
  ///      payload's shape: it must hold at least two 32-byte words, each an address with its top
  ///      twelve bytes zero, and it then decodes as a Handover whose two keys are nonzero and
  ///      distinct. A longer payload passes the shape check and fails the hash check in
  ///      validateSig, because the hash of its two addresses re-encoded does not equal the hash of
  ///      the longer payload. Fifth, the batch: the consume, the grant and the revoke, plus a
  ///      payment when the order has an amount. Sixth, the payee: the order's payee, or this
  ///      function's caller when the order names none, because this is the only step that knows
  ///      who sent the recovery. Last, the call: the batch goes to the account's execute under the
  ///      signature that routes validation to this action's slot.
  function executeHandover(address _account, bytes calldata _payload) external {
    IPolicyManager.Attempt memory _attempt = _spendableAttempt(_account);
    bytes32 _payloadHash = keccak256(_payload);
    require(
      _attempt.payloadHash == _payloadHash,
      RecoveryAction_NotConsumable(_account, _attempt.state, _attempt.consumableAfter, _attempt.payloadHash)
    );

    require(
      _payload.length > 63 && uint256(bytes32(_payload[0:32])) >> 160 == 0
        && uint256(bytes32(_payload[32:64])) >> 160 == 0,
      RecoveryAction_MalformedHandover(_payload)
    );
    Handover memory _handover = abi.decode(_payload, (Handover));
    _requireWellFormed(_handover, _payload);

    Transaction[] memory _calls = new Transaction[](_callCount(_attempt.order));
    _calls[_CONSUME_INDEX] = _consumeCall(address(MANAGER), address(this), _attempt.attemptId, _payloadHash);
    _calls[_GRANT_INDEX] = _grantCall(_account, _handover.newAuthority);
    _calls[_REVOKE_INDEX] = _revokeCall(_account, _handover.removedAuthority);
    if (_calls.length == _CALLS_WITH_PAYMENT) {
      address _payee = _attempt.order.payee == address(0) ? msg.sender : _attempt.order.payee;
      _calls[_PAYMENT_INDEX] = _paymentCall(_attempt.order, _payee);
    }

    bytes memory _signature =
      abi.encodePacked(abi.encode(KIT_SLOT, address(this), bytes(''), bytes('')), _VALIDATOR_SIGNATURE_MODE);
    IAmbireAccount(_account).execute(_calls, _signature);
  }

  /// @inheritdoc IAmbireRecoveryAction
  /// @dev Ambire's account calls this before it runs a batch sent under this action's slot, and
  ///      runs the batch only if this returns true. So the caller is the account. It first
  ///      requires the caller's code to be the one proxy this action serves. A batch can reach
  ///      this function without passing through executeHandover, so this check is needed here
  ///      too. It also refuses an address that delegates to the same implementation under
  ///      EIP-7702, whose own key would keep signing after the handover. This function
  ///      approves one batch only: the consume, the grant, the revoke and, when the order has an
  ///      amount, the payment. It checks the number of calls first, so no extra call can be added
  ///      after the approved ones. When the order has no payee, anyone may be paid, so it reads
  ///      the payee from the payment call: the target for the native asset, or the first argument
  ///      of transfer for a token. It then rebuilds the payment for that payee and compares it byte
  ///      for byte, so the token, the amount and the call itself cannot change. It reverts instead
  ///      of returning false. It does not use the data or the inner signature.
  function validateSig(bytes calldata, bytes calldata, Transaction[] calldata _calls)
    external
    view
    returns (bool _isValidSignature, uint256 _timestampValidAfter)
  {
    address _account = msg.sender;
    IPolicyManager.Attempt memory _attempt = _spendableAttempt(_account);

    uint256 _expectedCount = _callCount(_attempt.order);
    require(
      _calls.length == _expectedCount,
      RecoveryAction_BatchNotApproved(_calls.length < _expectedCount ? _calls.length : _expectedCount)
    );

    require(
      _sameCall(
        _calls[_CONSUME_INDEX], _consumeCall(address(MANAGER), address(this), _attempt.attemptId, _attempt.payloadHash)
      ),
      RecoveryAction_BatchNotApproved(_CONSUME_INDEX)
    );

    _requireApprovedHandover(_account, _calls, _attempt.payloadHash);
    if (_expectedCount == _CALLS_WITH_PAYMENT) {
      Transaction calldata _payment = _calls[_PAYMENT_INDEX];
      address _payee = _attempt.order.payee;
      if (_payee == address(0)) {
        _payee = _attempt.order.token == address(0) ? _payment.to : _firstAddressArgument(_payment.data);
      }
      require(
        _sameCall(_payment, _paymentCall(_attempt.order, _payee)), RecoveryAction_BatchNotApproved(_PAYMENT_INDEX)
      );
    }

    (_isValidSignature, _timestampValidAfter) = (true, 0);
  }

  /// @inheritdoc IPolicyAction
  /// @dev Compares the account's code hash with _PROXY_CODEHASH, the hash of the one proxy
  ///      this action serves, computed once in the constructor. Any other code answers false,
  ///      including an EIP-7702 delegation designator and an address with no code. The check
  ///      makes no call to the account. Only the full-width 45-byte proxy is served: its suffix
  ///      jumps to a fixed offset that is a jump destination only when the address is pushed at
  ///      twenty bytes, so a shortened proxy reverts every call and cannot be served.
  function supportsAccount(address _account) external view returns (bool _supported) {
    _supported = _isServed(_account);
  }

  /// @inheritdoc IPolicyAction
  function isAuthority(address _account, address _authority) external view returns (bool _holds) {
    _holds = _isKeyValue(IAmbireAccount(_account).privileges(_authority));
  }

  /// @inheritdoc IPolicyAction
  function isAuthorized(address _account) external view returns (bool _authorized) {
    _authorized = IAmbireAccount(_account).privileges(KIT_SLOT) == BINDING;
  }

  /// @inheritdoc IRecoveryAction
  function holdsAnyPrivilege(address _account, address _candidate) external view returns (bool _reserved) {
    _reserved = IAmbireAccount(_account).privileges(_candidate) != bytes32(0);
  }

  /// @inheritdoc IPolicyAction
  function supportsInterface(bytes4 _interfaceId) external pure returns (bool _supported) {
    _supported = _interfaceId == IPolicyAction.supportsInterface.selector
      || _interfaceId == type(IPolicyAction).interfaceId || _interfaceId == type(IRecoveryAction).interfaceId
      || _interfaceId == type(IAmbireRecoveryAction).interfaceId;
  }

  /// @inheritdoc IPolicyAction
  function name() external pure returns (string memory _actionName) {
    _actionName = 'AmbireRecoveryAction';
  }

  /// @inheritdoc IPolicyAction
  function version() external pure returns (string memory _actionVersion) {
    _actionVersion = '1.0.0';
  }

  /*///////////////////////////////////////////////////////////////
                         PRIVATE FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Whether this action serves the account: its code is the one proxy over
  ///         AMBIRE_IMPLEMENTATION.
  /// @dev Compares the account's code hash with _PROXY_CODEHASH and makes no call to the account.
  ///      An address with no code or with an EIP-7702 delegation designator answers false.
  /// @param _account The account checked.
  /// @return _served True when the account's code hash equals _PROXY_CODEHASH.
  function _isServed(address _account) private view returns (bool _served) {
    _served = _account.codehash == _PROXY_CODEHASH;
  }

  /// @notice Reads the account's attempt from the manager and requires it to be spendable now.
  /// @dev It first requires the account's code to be the one proxy this action serves, then reads
  ///      the attempt and requires it to be waiting with its wait over. It reads the time as a
  ///      uint48 and reverts if the time does not fit, the same way the manager reads it when it
  ///      spends the attempt. executeHandover and validateSig both start here.
  /// @param _account The account whose attempt is read.
  /// @return _attempt The account's attempt under this action.
  function _spendableAttempt(address _account) private view returns (IPolicyManager.Attempt memory _attempt) {
    require(_isServed(_account), RecoveryAction_AccountNotServed(_account));
    _attempt = MANAGER.stateOf(_account, address(this)).attempt;
    uint48 _now = SafeCast.toUint48(block.timestamp);
    require(
      _attempt.state == IPolicyManager.AttemptState.Waiting && !(_now < _attempt.consumableAfter),
      RecoveryAction_NotConsumable(_account, _attempt.state, _attempt.consumableAfter, _attempt.payloadHash)
    );
  }

  /// @notice Requires the grant and the revoke in the batch to install and remove the keys the
  ///         guardians approved, and requires the account to allow that change today.
  /// @dev The account hands this action the calls, not the payload, and this action knows the
  ///      approved payload only by its hash. So this function reads the two addresses from the
  ///      grant and revoke calls, encodes them as a Handover and checks that the hash equals the
  ///      approved one. That proves they are the approved keys. The hash does not cover the rest
  ///      of each call: the target, the value, and whether it writes 1 or 0. So this function
  ///      then rebuilds both calls in full and compares them byte for byte. Last, it checks the
  ///      account today: the new key holds no privilege, and the removed key is a key.
  /// @param _account The account running the batch.
  /// @param _calls The batch the account is about to run. Its length is already checked.
  /// @param _payloadHash The payload hash the guardians approved.
  function _requireApprovedHandover(address _account, Transaction[] calldata _calls, bytes32 _payloadHash)
    private
    view
  {
    Handover memory _handover =
      Handover(_firstAddressArgument(_calls[_GRANT_INDEX].data), _firstAddressArgument(_calls[_REVOKE_INDEX].data));
    bytes memory _rebuiltPayload = abi.encode(_handover);
    require(keccak256(_rebuiltPayload) == _payloadHash, RecoveryAction_BatchNotApproved(_GRANT_INDEX));
    _requireWellFormed(_handover, _rebuiltPayload);

    require(
      _sameCall(_calls[_GRANT_INDEX], _grantCall(_account, _handover.newAuthority)),
      RecoveryAction_BatchNotApproved(_GRANT_INDEX)
    );
    require(
      _sameCall(_calls[_REVOKE_INDEX], _revokeCall(_account, _handover.removedAuthority)),
      RecoveryAction_BatchNotApproved(_REVOKE_INDEX)
    );

    require(
      IAmbireAccount(_account).privileges(_handover.newAuthority) == bytes32(0),
      RecoveryAction_AlreadyPrivileged(_handover.newAuthority)
    );
    require(
      _isKeyValue(IAmbireAccount(_account).privileges(_handover.removedAuthority)),
      RecoveryAction_NotAKey(_handover.removedAuthority)
    );
  }

  /// @notice Builds the first call of the batch: the manager's consume, which spends the attempt.
  /// @dev The consume runs inside the same batch as the key change. If either fails, the whole
  ///      batch reverts, so the attempt is never spent without the key change, or the reverse.
  /// @param _manager The policy manager that holds the attempt.
  /// @param _action This action, which the manager spends the attempt for.
  /// @param _attemptId The id of the attempt being spent.
  /// @param _payloadHash The payload hash the manager checks against the approved one.
  /// @return _call A call to the manager's consume, with no value.
  function _consumeCall(address _manager, address _action, uint64 _attemptId, bytes32 _payloadHash)
    private
    pure
    returns (Transaction memory _call)
  {
    _call = Transaction({
      to: _manager, value: 0, data: abi.encodeCall(IPolicyManager.consume, (_action, _attemptId, _payloadHash))
    });
  }

  /// @notice Builds the grant: the account's call to itself, setAddrPrivilege(newKey, 1), which
  ///         makes the new key a key of the account.
  /// @param _account The account, which is also the target of the call.
  /// @param _newAuthority The new key.
  /// @return _call The grant call, with no value.
  function _grantCall(address _account, address _newAuthority) private pure returns (Transaction memory _call) {
    _call = Transaction({
      to: _account, value: 0, data: abi.encodeCall(IAmbireAccount.setAddrPrivilege, (_newAuthority, KEY_VALUE))
    });
  }

  /// @notice Builds the revoke: the account's call to itself, setAddrPrivilege(lostKey, 0), which
  ///         removes the lost key.
  /// @param _account The account, which is also the target of the call.
  /// @param _removedAuthority The lost key.
  /// @return _call The revoke call, with no value.
  function _revokeCall(address _account, address _removedAuthority) private pure returns (Transaction memory _call) {
    _call = Transaction({
      to: _account, value: 0, data: abi.encodeCall(IAmbireAccount.setAddrPrivilege, (_removedAuthority, bytes32(0)))
    });
  }

  /// @notice Builds the payment. For a token, it is a transfer(payee, amount) call to the token.
  ///         For the native asset, it is a call to the payee with the amount and no data.
  /// @dev Nothing reads the token's return value. A token that returns false instead of reverting
  ///      therefore leaves the recovery done and the payee unpaid. This is on purpose: a bad token
  ///      cannot block the recovery.
  /// @param _order The payment order the guardians approved.
  /// @param _payee The address paid: the order's payee, or the chosen payee when the order has none.
  /// @return _call The payment call.
  function _paymentCall(IPolicyManager.PaymentOrder memory _order, address _payee)
    private
    pure
    returns (Transaction memory _call)
  {
    _call = _order.token == address(0)
      ? Transaction({to: _payee, value: _order.amount, data: ''})
      : Transaction({to: _order.token, value: 0, data: abi.encodeCall(IERC20.transfer, (_payee, _order.amount))});
  }

  /// @notice The number of calls in the batch for an order: four when the order has an amount, so
  ///         the payment follows the consume, the grant and the revoke, and three otherwise.
  /// @param _order The payment order the guardians approved.
  /// @return _count The number of calls the batch holds.
  function _callCount(IPolicyManager.PaymentOrder memory _order) private pure returns (uint256 _count) {
    _count = _order.amount != 0 ? _CALLS_WITH_PAYMENT : _CALLS_WITHOUT_PAYMENT;
  }

  /// @notice Reverts when the handover names the zero address as either key, or the same address
  ///         as both keys.
  /// @param _handover The handover to check.
  /// @param _payload The payload reported in the error.
  function _requireWellFormed(Handover memory _handover, bytes memory _payload) private pure {
    require(
      _handover.newAuthority != address(0) && _handover.removedAuthority != address(0)
        && _handover.newAuthority != _handover.removedAuthority,
      RecoveryAction_MalformedHandover(_payload)
    );
  }

  /// @notice A call's data is a 4-byte selector followed by its arguments. This returns the first
  ///         argument read as an address: for example the key in setAddrPrivilege(key, value) or
  ///         the recipient in transfer(to, amount).
  /// @dev It keeps only the low twenty bytes and ignores the rest of the word. That is safe
  ///      because the caller then rebuilds the whole call and compares it byte for byte.
  /// @param _data The call's data.
  /// @return _argument The address read, or zero when the data is too short to hold one.
  function _firstAddressArgument(bytes calldata _data) private pure returns (address _argument) {
    if (_data.length > 35) _argument = address(uint160(uint256(bytes32(_data[4:36]))));
  }

  /// @notice Whether two calls are the same: the same target, the same value and the same data.
  /// @param _call The call found in the batch.
  /// @param _expected The call this action builds.
  /// @return _same True when the two calls are identical.
  function _sameCall(Transaction calldata _call, Transaction memory _expected) private pure returns (bool _same) {
    _same =
      _call.to == _expected.to && _call.value == _expected.value && keccak256(_call.data) == keccak256(_expected.data);
  }

  /// @notice Whether a privilege value marks a key, an address that can sign for the account.
  ///         Keys hold 1 or 2. Any other nonzero value marks a contract the account trusts.
  /// @param _privilege The value read from the account's privileges.
  /// @return _isKey True when the value is 1 or 2.
  function _isKeyValue(bytes32 _privilege) private pure returns (bool _isKey) {
    _isKey = _privilege == KEY_VALUE || _privilege == _RESERVED_KEY_VALUE;
  }
}
