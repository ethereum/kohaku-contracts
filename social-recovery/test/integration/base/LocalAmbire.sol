// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';

/// @notice The validator callback Ambire's account makes on its external-signature route.
interface ILocalAmbireValidator {
  function validateSig(bytes calldata data, bytes calldata sig, IAmbireRecoveryAction.Transaction[] calldata calls)
    external
    returns (bool isValidSignature, uint256 timestampValidAfter);
}

/// @notice A stand-in for Ambire's AmbireAccount implementation, deployed behind the same 45-byte proxy Ambire's
///         factory builds.
/// @dev What it replaces: the implementation at 0x0F2AA7bcda3d9D210dF69a394b6965CB2566c828, which the action
///      pins. Why the real one is not used: that code exists only on mainnet and Sepolia, its source targets
///      solc 0.8.19 and is not vendored here, and the local chain has no copy of it. Which tests cover the real
///      one: test/action/fork/AmbireAccountFork.t.sol and test/action/fork/AmbireRecoveryActionSpendFork.t.sol run
///      the kit against the deployed implementation on forks of both chains.
///      It transcribes, from the verified source of that implementation (an exact Sourcify match), what the stories
///      touch: the privilege table at slot 0, `setAddrPrivilege` only from the account itself, `execute` on both
///      routes (a slot-bound validator for a signature ending in 255, else a key's signature over
///      keccak256(account, chain id, nonce, calls) in the account-bound form), `executeMultiple`, `executeBySender`
///      for a privileged caller, the anti-bricking check after every batch, the batch loop that skips a call to
///      address(0), a fallback that delegates any unknown call to the handler named under 0x6969 and answers with
///      nothing when none is set, `validateUserOp` with its sponsored path for an empty signature, and the ERC-1271
///      rule: a key at 2 may sign a hash in the unprotected form, while a key at 1 must sign the account-bound form.
///      Of the signature validator it keeps the two ECDSA modes the stories sign with: unprotected, a signature over
///      the hash itself, and standard, a signature over the EIP-712 AmbireOperation(account, hash) envelope. The other
///      modes revert here. The fallback follows the deployed implementation, not the reference source, whose
///      fallback is empty.
// The transcription keeps Ambire's own revert strings and comparisons.
// solhint-disable gas-custom-errors, reason-string, gas-strict-inequalities
contract LocalAmbireAccount {
  /// @notice One bundle of executeMultiple: a batch and its signature.
  struct ExecuteArgs {
    IAmbireRecoveryAction.Transaction[] calls;
    bytes signature;
  }

  /// @notice The privilege value Ambire writes for an ERC-4337 entry point.
  bytes32 public constant ENTRY_POINT_MARKER = bytes32(uint256(0x7171));
  /// @notice The signature mode of a signature over the hash itself, with no account in it.
  uint8 public constant SIGMODE_UNPROTECTED = 0;
  /// @notice The signature mode of a signature over the EIP-712 envelope that binds the hash to the account.
  uint8 public constant SIGMODE_STANDARD = 1;
  /// @notice The signature mode that routes to a slot-bound validator.
  uint8 public constant SIGMODE_EXTERNALLY_VALIDATED = 255;
  /// @notice The first mode byte past the validator's modes; a 65-byte signature with such a byte is unprotected.
  uint8 internal constant _SIGMODE_LAST_UNUSED = 6;

  /// @notice The privilege key whose entry names the fallback handler on the deployed implementation.
  address internal constant _FALLBACK_HANDLER_SLOT = address(0x6969);
  /// @notice The privilege table, address to value, at storage slot 0.
  mapping(address _addr => bytes32 _privilege) public privileges;
  /// @notice The execute nonce.
  uint256 public nonce;

  /// @notice Ambire's event for one privilege write.
  event LogPrivilegeChanged(address indexed addr, bytes32 priv);

  /// @notice Accepts the native asset.
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

  /// @notice Runs several signed batches in order, each through `execute`.
  function executeMultiple(ExecuteArgs[] calldata toExec) external payable {
    for (uint256 _i; _i != toExec.length; ++_i) {
      execute(toExec[_i].calls, toExec[_i].signature);
    }
  }

  /// @notice Runs a batch for a caller that holds a privilege, with no signature.
  function executeBySender(IAmbireRecoveryAction.Transaction[] calldata calls) external payable {
    require(privileges[msg.sender] != bytes32(0), 'INSUFFICIENT_PRIVILEGE');
    _executeBatch(calls);
    require(privileges[msg.sender] != bytes32(0), 'PRIVILEGE_NOT_DOWNGRADED');
  }

  /// @notice ERC-4337 v0.7 validation, 0 for success and 1 for failure. An operation calling `executeMultiple` skips
  ///         the entry point check and the operation signature: it must carry an empty signature, a paymaster, and a
  ///         nonce that commits to the operation, and each bundle's own signature then decides what runs. Any other
  ///         operation must come from an entry point holding ENTRY_POINT_MARKER and be signed by a privileged key in
  ///         the account-bound form. The entry point is paid what it says is missing.
  function validateUserOp(
    LocalEntryPoint.PackedUserOperation calldata op,
    bytes32 userOpHash,
    uint256 missingAccountFunds
  ) external payable returns (uint256 validationData) {
    // Reading the selector and the paymaster keeps the leading bytes on purpose.
    // forge-lint: disable-next-line(unsafe-typecast)
    if (op.callData.length >= 4 && bytes4(op.callData[0:4]) == this.executeMultiple.selector) {
      if (op.signature.length != 0) return 1;
      require(
        // forge-lint: disable-next-line(unsafe-typecast)
        op.paymasterAndData.length >= 52 && bytes20(op.paymasterAndData[:20]) != bytes20(0),
        'validateUserOp: paymaster required in execute() mode'
      );
      uint256 _targetNonce = uint256(
        keccak256(
          abi.encode(
            op.initCode, op.callData, op.accountGasLimits, op.preVerificationGas, op.gasFees, op.paymasterAndData
          )
        )
      ) << 64;
      if (op.nonce != _targetNonce) return 1;
      return 0;
    }
    require(privileges[msg.sender] == ENTRY_POINT_MARKER, 'validateUserOp: not from entryPoint');
    if (missingAccountFunds > 0) {
      (bool _success,) = msg.sender.call{value: missingAccountFunds}('');
      _success;
    }
    validationData = privileges[_recoverAddr(userOpHash, op.signature)] != bytes32(0) ? 0 : 1;
  }

  /// @notice ERC-1271. A signature in the unprotected form counts only for a key above 1, and one in the
  ///         account-bound form counts for any key.
  function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue) {
    (address _recovered, bool _usedUnprotected) = _recoverAddrAllowUnprotected(hash, signature);
    magicValue = uint256(privileges[_recovered]) > (_usedUnprotected ? 1 : 0) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
  }

  /// @notice Runs a batch under a signature, then requires the signer to still hold a privilege.
  function execute(IAmbireRecoveryAction.Transaction[] calldata calls, bytes calldata signature) public payable {
    address _signerKey;
    uint8 _sigMode = uint8(signature[signature.length - 1]);
    uint256 _currentNonce = nonce;
    nonce = _currentNonce + 1;
    if (_sigMode == SIGMODE_EXTERNALLY_VALIDATED) {
      bool _isValidSig;
      uint256 _timestampValidAfter;
      (_signerKey, _isValidSig, _timestampValidAfter) = _validateExternalSig(calls, signature);
      if (!_isValidSig) {
        // The transcription keeps Ambire's own timelock check.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp >= _timestampValidAfter, 'SIGNATURE_VALIDATION_TIMELOCK');
        revert('SIGNATURE_VALIDATION_FAIL');
      }
    } else {
      _signerKey = _recoverAddr(keccak256(abi.encode(address(this), block.chainid, _currentNonce, calls)), signature);
      require(privileges[_signerKey] != bytes32(0), 'INSUFFICIENT_PRIVILEGE');
    }
    _executeBatch(calls);
    require(privileges[_signerKey] != bytes32(0), 'PRIVILEGE_NOT_DOWNGRADED');
  }

  /// @notice Recovers the signer and requires the account-bound form, as the account does for batches and
  ///         operations.
  function _recoverAddr(bytes32 _hash, bytes calldata _signature) internal view returns (address _signer) {
    bool _usedUnprotected;
    (_signer, _usedUnprotected) = _recoverAddrAllowUnprotected(_hash, _signature);
    require(!_usedUnprotected, 'SV_USED_UNBOUND');
  }

  /// @notice Recovers the signer of r, s, v and an optional mode byte, and says whether the signature was over the
  ///         hash itself rather than over the account-bound envelope.
  function _recoverAddrAllowUnprotected(bytes32 _hash, bytes calldata _signature)
    internal
    view
    returns (address _signer, bool _usedUnprotected)
  {
    require(_signature.length != 0, 'SV_SIGLEN');
    uint8 _mode = uint8(_signature[_signature.length - 1]);
    if (_mode >= _SIGMODE_LAST_UNUSED) {
      if (_signature.length == 65) _mode = SIGMODE_UNPROTECTED;
      else revert('SV_SIGMODE');
    }
    require(_mode == SIGMODE_UNPROTECTED || _mode == SIGMODE_STANDARD, 'SV_TYPE');
    _usedUnprotected = _mode == SIGMODE_UNPROTECTED;
    if (!_usedUnprotected) _hash = _ambireOperationHash(_hash);
    require(_signature.length == 65 || _signature.length == 66, 'SV_LEN');
    _signer = ecrecover(_hash, uint8(_signature[64]), bytes32(_signature[0:32]), bytes32(_signature[32:64]));
    require(_signer != address(0), 'SV_ZERO_SIG');
  }

  /// @notice Requires the slot to hold the validator's binding and asks the validator.
  function _validateExternalSig(IAmbireRecoveryAction.Transaction[] calldata _calls, bytes calldata _signature)
    internal
    returns (address _signerKey, bool _isValidSig, uint256 _timestampValidAfter)
  {
    (address _slot, address _validator, bytes memory _data, bytes memory _innerSig) =
      abi.decode(_signature[:_signature.length - 1], (address, address, bytes, bytes));
    require(privileges[_slot] == keccak256(abi.encode(_validator, _data)), 'EXTERNAL_VALIDATION_NOT_SET');
    _signerKey = _slot;
    (_isValidSig, _timestampValidAfter) = ILocalAmbireValidator(_validator).validateSig(_data, _innerSig, _calls);
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

  /// @notice The EIP-712 AmbireOperation(account, hash) envelope under the domain named Ambire, version 1, this
  ///         chain, this account and a zero salt.
  function _ambireOperationHash(bytes32 _hash) internal view returns (bytes32 _envelope) {
    bytes32 _domainSeparator = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)'),
        keccak256('Ambire'),
        keccak256('1'),
        block.chainid,
        address(this),
        bytes32(0)
      )
    );
    _envelope = keccak256(
      abi.encodePacked(
        '\x19\x01',
        _domainSeparator,
        keccak256(abi.encode(keccak256('AmbireOperation(address account,bytes32 hash)'), address(this), _hash))
      )
    );
  }
}

// solhint-enable gas-custom-errors, reason-string, gas-strict-inequalities

/// @notice A stand-in for Ambire's account factory (contracts/AmbireFactory.sol): CREATE2 of the proxy creation code,
///         and the deploy-and-execute entry a counterfactual account's first batch goes through.
/// @dev What it replaces: the factory at 0x26cE6745A633030A6faC5e64e41D21fb6246dc2d. Why the real one is not
///      used: it exists only on mainnet and Sepolia. Which test covers the real one:
///      test/action/fork/AmbireAccountFork.t.sol builds accounts through it on forks.
contract LocalAmbireFactory {
  /// @notice The CREATE2 returned no address.
  error LocalAmbireFactory_DeployFailed();

  /// @notice Deploys the creation code under the salt, or returns the account already there.
  function deploy(bytes calldata _code, uint256 _salt) public returns (address _account) {
    _account = _computeAddress(_code, _salt);
    if (_account.code.length != 0) return _account;
    bytes memory _initCode = _code;
    assembly {
      _account := create2(0, add(_initCode, 0x20), mload(_initCode), _salt)
    }
    require(_account != address(0), LocalAmbireFactory_DeployFailed());
  }

  /// @notice Deploys the account, then runs its first signed batch, in one transaction.
  function deployAndExecute(
    bytes calldata _code,
    uint256 _salt,
    IAmbireRecoveryAction.Transaction[] calldata _calls,
    bytes calldata _signature
  ) external returns (address _account) {
    _account = deploy(_code, _salt);
    LocalAmbireAccount(payable(_account)).execute(_calls, _signature);
  }

  /// @notice The address an account with this creation code and salt has, deployed or not. Internal, since the real
  ///         factory exposes no such view and a client computes the address itself.
  function _computeAddress(bytes calldata _code, uint256 _salt) internal view returns (address _account) {
    _account =
      address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(_code))))));
  }
}

/// @notice A stand-in for an ERC-4337 v0.7 entry point with paymaster deposits and keyed nonces, reduced to one
///         operation per call.
/// @dev What it replaces: the canonical EntryPoint v0.7 and a paymaster. Why the real one is not used: the local chain
///      has none, and the stories need only who signs, who pays and what runs. It takes the v0.7 packed operation,
///      hashes it as v0.7 does, validates through the account's validateUserOp with nothing missing, charges the
///      paymaster named in the first twenty bytes of paymasterAndData a fixed fee paid to the bundler, then calls the
///      account with the operation's call data. Unlike the real entry point, a failing execution reverts the whole
///      call, so a story sees the account's own refusal. On a fork the account is Ambire's deployed implementation, so
///      the account side runs for real; no test in this repository runs the kit through the canonical entry point.
contract LocalEntryPoint {
  /// @notice The ERC-4337 v0.7 packed user operation, field for field.
  struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
  }

  /// @notice The fee each operation costs its paymaster, paid to the bundler.
  uint256 public constant OPERATION_FEE = 0.001 ether;

  /// @notice Each paymaster's deposit.
  mapping(address _paymaster => uint256 _deposit) public deposits;
  /// @notice Each sender's next sequence number under each nonce key.
  mapping(address _sender => mapping(uint192 _key => uint64 _sequence)) public nonceSequences;

  /// @notice The account's validation refused the operation.
  error LocalEntryPoint_InvalidSignature();
  /// @notice The operation's nonce is not the sender's next one.
  error LocalEntryPoint_WrongNonce();
  /// @notice The paymaster's deposit does not cover the fee.
  error LocalEntryPoint_PaymasterDepositTooLow();

  /// @notice Adds to a paymaster's deposit.
  function depositTo(address _paymaster) external payable {
    deposits[_paymaster] += msg.value;
  }

  /// @notice A sender's next nonce under a key: the key in the high 192 bits, the sequence in the low 64.
  function getNonce(address _sender, uint192 _key) public view returns (uint256 _nonce) {
    _nonce = (uint256(_key) << 64) | nonceSequences[_sender][_key];
  }

  /// @notice The hash a sender's key signs for an operation, as v0.7 builds it: the packed fields with each dynamic
  ///         field hashed, then that hash with this entry point and the chain id.
  function getUserOpHash(PackedUserOperation calldata _op) public view returns (bytes32 _hash) {
    bytes32 _packed = keccak256(
      abi.encode(
        _op.sender,
        _op.nonce,
        keccak256(_op.initCode),
        keccak256(_op.callData),
        _op.accountGasLimits,
        _op.preVerificationGas,
        _op.gasFees,
        keccak256(_op.paymasterAndData)
      )
    );
    _hash = keccak256(abi.encode(_packed, address(this), block.chainid));
  }

  /// @notice Validates and runs one operation, charging its paymaster.
  function handleOp(PackedUserOperation calldata _op) external {
    // The nonce packs the key over the sequence, and paymasterAndData starts with the paymaster, so each cast keeps
    // the bits it names.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint192 _key = uint192(_op.nonce >> 64);
    // forge-lint: disable-next-line(unsafe-typecast)
    require(uint64(_op.nonce) == nonceSequences[_op.sender][_key], LocalEntryPoint_WrongNonce());
    ++nonceSequences[_op.sender][_key];
    // forge-lint: disable-next-line(unsafe-typecast)
    address _paymaster = _op.paymasterAndData.length < 20 ? address(0) : address(bytes20(_op.paymasterAndData[:20]));
    require(deposits[_paymaster] > OPERATION_FEE - 1, LocalEntryPoint_PaymasterDepositTooLow());
    deposits[_paymaster] -= OPERATION_FEE;
    uint256 _validation = LocalAmbireAccount(payable(_op.sender)).validateUserOp(_op, getUserOpHash(_op), 0);
    require(_validation == 0, LocalEntryPoint_InvalidSignature());
    (bool _ok, bytes memory _ret) = _op.sender.call(_op.callData);
    if (!_ok) {
      assembly {
        revert(add(_ret, 0x20), mload(_ret))
      }
    }
    (bool _paid,) = msg.sender.call{value: OPERATION_FEE}('');
    _paid;
  }
}
