// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';

/// @notice The validator side of Ambire's account, as the account calls it. Ambire's abstract
///         ExternalSigValidator (kohaku-commons 29227cc, contracts/ExternalSigValidator.sol lines
///         20-26) declares this one function, and the fixture calls it through this declaration.
interface IActionAmbireValidator {
  function validateSig(bytes calldata data, bytes calldata sig, IAmbireRecoveryAction.Transaction[] calldata calls)
    external
    returns (bool isValidSignature, uint256 timestampValidAfter);
}

/// @notice A Solidity transcription of the parts of Ambire's AmbireAccount (kohaku-commons 29227cc,
///         contracts/AmbireAccount.sol) that a recovery touches, deployed as the implementation
///         behind the proxy Ambire's factory builds. It keeps the privilege mapping as the first
///         state variable, at slot 0, because the deployed implementation and the factory's proxy
///         builder keep it there, so the proxy's creation code writes the first key straight into
///         it. It transcribes `setAddrPrivilege` (lines 97-101), `execute` on its validator route
///         (lines 140-172) with the external-signature validation (lines 326-357), `executeBySender`
///         (lines 187-192), the batch loop `executeBatch` that skips a call to the zero address
///         (lines 219-225) and `executeCall`, which bubbles a failing call's revert data (lines
///         234-245). The source is github.com/ethereum/kohaku-commons. The signature route that
///         recovers an ECDSA signer is not transcribed: the fixture refuses it, since no recovery
///         reaches it. Its fallback follows the deployed implementation rather than that source:
///         it delegates an unknown call to the handler named under 0x6969, when one is set.
// The transcription keeps Ambire's own revert strings and comparisons, so it reverts as the account does.
// solhint-disable gas-custom-errors, reason-string, gas-strict-inequalities
contract ActionAmbireAccountFixture {
  /*///////////////////////////////////////////////////////////////
                          STATE VARIABLES
  ///////////////////////////////////////////////////////////////*/

  /// @notice The privilege key whose entry names the fallback handler on the deployed implementation.
  address internal constant _FALLBACK_HANDLER_SLOT = address(0x6969);
  /// @notice The privilege table, address to value, at storage slot 0.
  mapping(address _addr => bytes32 _privilege) public privileges;
  /// @notice The execute nonce, raised before any validation runs.
  uint256 public nonce;

  /*///////////////////////////////////////////////////////////////
                              EVENTS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Ambire's event for one privilege write.
  event LogPrivilegeChanged(address indexed addr, bytes32 priv);

  /*///////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Accepts the native asset without data, as the account does.
  receive() external payable {}

  /// @notice Runs the fallback handler on any unknown call, as the deployed implementation does. It reads the
  ///         privilege entry under 0x6969 and keeps its low twenty bytes as the handler's address. When that
  ///         address is nonzero, the call is delegated with its whole calldata to it, so the handler runs in the
  ///         account's own storage, and the account returns or reverts with the handler's returndata. When it is
  ///         zero, whatever the upper bytes of the entry hold, the call is accepted and returns nothing.
  // solhint-disable-next-line no-complex-fallback
  fallback() external payable {
    address _handler = address(uint160(uint256(privileges[_FALLBACK_HANDLER_SLOT])));
    if (_handler == address(0)) return;
    assembly {
      calldatacopy(0, 0, calldatasize())
      let _result := delegatecall(gas(), _handler, 0, calldatasize(), 0, 0)
      returndatacopy(0, 0, returndatasize())
      if iszero(_result) { revert(0, returndatasize()) }
      return(0, returndatasize())
    }
  }

  /// @notice Writes one privilege entry. Only the account itself may call it.
  function setAddrPrivilege(address addr, bytes32 priv) external payable {
    require(msg.sender == address(this), 'ONLY_ACCOUNT_CAN_CALL');
    privileges[addr] = priv;
    emit LogPrivilegeChanged(addr, priv);
  }

  /// @notice Runs a batch once the validator bound under the signature's slot approves it. The
  ///         last byte of the signature is the mode, 255 for an externally validated signature.
  ///         After the batch the slot must still hold a nonzero entry.
  function execute(IAmbireRecoveryAction.Transaction[] calldata calls, bytes calldata signature) external payable {
    uint8 _sigMode = uint8(signature[signature.length - 1]);
    nonce = nonce + 1;
    require(_sigMode == 255, 'FIXTURE_ONLY_MODELS_THE_VALIDATOR_ROUTE');
    (address _signerKey, bool _isValidSig, uint256 _timestampValidAfter) = _validateExternalSig(calls, signature);
    if (!_isValidSig) {
      // The transcription keeps Ambire's timelock comparison as the account makes it.
      // forge-lint: disable-next-line(block-timestamp)
      require(block.timestamp >= _timestampValidAfter, 'SIGNATURE_VALIDATION_TIMELOCK');
      revert('SIGNATURE_VALIDATION_FAIL');
    }
    _executeBatch(calls);
    require(privileges[_signerKey] != bytes32(0), 'PRIVILEGE_NOT_DOWNGRADED');
  }

  /// @notice Runs a batch for a caller that holds a privilege entry, with no signature.
  function executeBySender(IAmbireRecoveryAction.Transaction[] calldata calls) external payable {
    require(privileges[msg.sender] != bytes32(0), 'INSUFFICIENT_PRIVILEGE');
    _executeBatch(calls);
    require(privileges[msg.sender] != bytes32(0), 'PRIVILEGE_NOT_DOWNGRADED');
  }

  /*///////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Decodes the slot, the validator, its data and the inner signature, requires the slot
  ///         to hold the validator's binding, and asks the validator.
  function _validateExternalSig(IAmbireRecoveryAction.Transaction[] calldata _calls, bytes calldata _signature)
    internal
    returns (address _signerKey, bool _isValidSig, uint256 _timestampValidAfter)
  {
    (address _slot, address _validator, bytes memory _data, bytes memory _innerSig) =
      abi.decode(_signature[:_signature.length - 1], (address, address, bytes, bytes));
    require(privileges[_slot] == keccak256(abi.encode(_validator, _data)), 'EXTERNAL_VALIDATION_NOT_SET');
    _signerKey = _slot;
    (_isValidSig, _timestampValidAfter) = IActionAmbireValidator(_validator).validateSig(_data, _innerSig, _calls);
  }

  /// @notice Runs each call in order, skipping a call to the zero address.
  function _executeBatch(IAmbireRecoveryAction.Transaction[] calldata _calls) internal {
    for (uint256 _i; _i < _calls.length; ++_i) {
      if (_calls[_i].to != address(0)) _executeCall(_calls[_i].to, _calls[_i].value, _calls[_i].data);
    }
  }

  /// @notice Makes one call and, when it fails, reverts with the call's own revert data.
  function _executeCall(address _to, uint256 _value, bytes memory _data) internal {
    assembly {
      let _result := call(gas(), _to, _value, add(_data, 0x20), mload(_data), 0, 0)
      if eq(_result, 0) {
        let _size := returndatasize()
        let _ptr := mload(0x40)
        returndatacopy(_ptr, 0, _size)
        revert(_ptr, _size)
      }
    }
  }
}

// solhint-enable gas-custom-errors, reason-string, gas-strict-inequalities

/// @notice A minimal ERC-20 for payment orders. It can be switched to answer false without moving
///         anything, the nonstandard shape a raw payment call leaves unnoticed.
contract ActionPaymentToken {
  /// @notice Balances.
  mapping(address _holder => uint256 _balance) public balanceOf;
  /// @notice When true, transfer moves nothing and returns false.
  bool public answersFalse;

  /// @notice Raised when a transfer exceeds the sender's balance.
  error ActionPaymentToken_Insufficient(address _from, uint256 _balance, uint256 _amount);

  /// @notice Credits `_amount` to `_to`.
  function mint(address _to, uint256 _amount) external {
    balanceOf[_to] += _amount;
  }

  /// @notice Chooses whether transfer answers false.
  function setAnswersFalse(bool _answersFalse) external {
    answersFalse = _answersFalse;
  }

  /// @notice Moves `_amount` from the caller to `_to`, or answers false and moves nothing.
  function transfer(address _to, uint256 _amount) external returns (bool _ok) {
    if (answersFalse) return false;
    uint256 _balance = balanceOf[msg.sender];
    require(!(_balance < _amount), ActionPaymentToken_Insufficient(msg.sender, _balance, _amount));
    balanceOf[msg.sender] = _balance - _amount;
    balanceOf[_to] += _amount;
    _ok = true;
  }
}

/// @notice A payee that refuses the native asset.
contract ActionRefusingPayee {
  /// @notice The refusal.
  error ActionRefusingPayee_Refused();

  /// @notice Refuses every payment.
  receive() external payable {
    revert ActionRefusingPayee_Refused();
  }
}

/// @notice A payee that, when paid in the native asset, calls the account again while it is being paid,
///         sending a batch and a signature it was handed, and records whether that nested run
///         succeeded and what it reverted with. It never reverts itself, so the outer batch can run.
contract ActionCallbackPayee {
  /// @notice The account to call again while being paid.
  address public account;
  /// @notice The signature of the nested run.
  bytes public signature;
  /// @notice How many nested runs were attempted.
  uint256 public attempts;
  /// @notice How many nested runs succeeded.
  uint256 public successes;
  /// @notice The revert data of the last nested run that failed.
  bytes public lastRevert;
  /// @notice The batch of the nested run.
  IAmbireRecoveryAction.Transaction[] internal _calls;

  /// @notice Stores the batch the payee sends again when paid.
  function load(address _account, IAmbireRecoveryAction.Transaction[] calldata _batch, bytes calldata _signature)
    external
  {
    account = _account;
    signature = _signature;
    delete _calls;
    for (uint256 _i; _i < _batch.length; ++_i) {
      _calls.push(_batch[_i]);
    }
  }

  /// @notice Sends the stored batch to the account once per payment.
  // solhint-disable-next-line no-complex-fallback
  receive() external payable {
    if (account == address(0)) return;
    ++attempts;
    (bool _ok, bytes memory _ret) =
      account.call(abi.encodeWithSignature('execute((address,uint256,bytes)[],bytes)', _calls, signature));
    if (_ok) ++successes;
    else lastRevert = _ret;
  }
}
