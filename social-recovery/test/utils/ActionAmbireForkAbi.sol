// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';

/// @notice The one call the fork tests make on a deployed Ambire account that the action never
///         makes, so the action's own IAmbireAccount does not declare it: the privileged signer's
///         batch, from Ambire's source (kohaku-commons 29227cc, contracts/deployless/IAmbireAccount.sol
///         lines 23-30). It mirrors Ambire's declaration, so it keeps Ambire's names.
interface IActionAmbireSender {
  function executeBySender(IAmbireRecoveryAction.Transaction[] calldata calls) external payable;
}

/// @notice Ambire's factory, contracts/AmbireFactory.sol line 28. It mirrors Ambire's declaration,
///         so it keeps Ambire's names.
interface IActionAmbireFactory {
  function deploy(bytes calldata code, uint256 salt) external returns (address deployed);
}

/// @notice A validator in the shape Ambire's abstract validator declares
///         (contracts/ExternalSigValidator.sol lines 20-26). It approves every batch, so a fork
///         test can drive the account's execute through the validator route.
contract ActionForkApprovingValidator {
  function validateSig(bytes calldata, bytes calldata, IAmbireRecoveryAction.Transaction[] calldata)
    external
    pure
    returns (bool _isValidSignature, uint256 _timestampValidAfter)
  {
    _isValidSignature = true;
    _timestampValidAfter = 0;
  }
}

/// @notice A call target that fails with a custom error carrying values.
contract ActionForkRefusingTarget {
  /// @notice The refusal the target raises, carrying a number and a string.
  error ActionForkRefusingTarget_Refused(uint256 _code, string _reason);

  function refuse() external pure {
    revert ActionForkRefusingTarget_Refused(42, 'inner');
  }
}

/// @notice A call target that succeeds and counts.
contract ActionForkCountingTarget {
  uint256 public count;

  function bump() external {
    ++count;
  }
}

/// @notice A fallback handler an account can name under 0x6969. Run by delegatecall, it writes a word into
///         the calling account's storage at a fixed slot and returns the address it runs as.
contract ActionForkFallbackHandler {
  /// @notice The storage slot the handler writes in whatever account runs it.
  bytes32 public constant MARK_SLOT = keccak256('action.fork.fallbackHandler.mark');

  /// @notice Writes `_value` at MARK_SLOT of the running account and returns that account's address.
  function mark(bytes32 _value) external returns (address _self) {
    bytes32 _slot = MARK_SLOT;
    assembly {
      sstore(_slot, _value)
    }
    _self = address(this);
  }
}
