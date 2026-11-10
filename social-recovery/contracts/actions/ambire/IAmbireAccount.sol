// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';

/// @title IAmbireAccount
/// @notice The minimal local ABI the recovery action uses for Ambire's AmbireAccount.
///         It is copied from AmbireAccount at kohaku-commons commit
///         29227cc7c13617ccbe0c8b737d1678d30c2c4047 rather than imported as a package.
/// @dev That commit has no release tag to pin and targets Solidity 0.8.19, so the kit copies
///      only the calls the recovery action makes. It describes one account implementation
///      rather than a kit interface. It mirrors Ambire's source, so it keeps Ambire's names of
///      functions, events and parameters, and Ambire's member order, and ABIs decode the way
///      upstream tools expect. It names a return value only where Ambire leaves it unnamed and
///      the linter needs a name, as `privilege`.
interface IAmbireAccount {
  /*///////////////////////////////////////////////////////////////
                              EVENTS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The account wrote one entry of its privilege mapping.
  /// @param addr The address whose entry was written.
  /// @param priv The value written, zero when the entry was removed.
  event LogPrivilegeChanged(address indexed addr, bytes32 priv);

  /*///////////////////////////////////////////////////////////////
                              LOGIC
  ///////////////////////////////////////////////////////////////*/

  /// @notice The account's privilege entry for one address.
  /// @dev A zero entry grants nothing. A value of 1 or 2 marks a key. Any other nonzero value
  ///      marks code the account trusts.
  /// @param key The address asked about.
  /// @return privilege The entry the account holds for that address.
  function privileges(address key) external view returns (bytes32 privilege);

  /// @notice Write one entry of the account's privilege mapping.
  /// @dev Only the account itself may call it, so every write runs inside a batch.
  /// @param addr The address whose entry is written.
  /// @param priv The value written.
  // Ambire declares this after the privileges view, and the mirror keeps Ambire's order.
  // solhint-disable-next-line ordering
  function setAddrPrivilege(address addr, bytes32 priv) external payable;

  /// @notice Run a batch of calls under a signature the account validates first.
  /// @dev A signature ending in the byte 255 routes validation to a slot-bound validator's
  ///      validateSig callback.
  /// @param calls The batch to run, all or nothing.
  /// @param signature The signature. Its last byte names the signature mode.
  function execute(IAmbireRecoveryAction.Transaction[] calldata calls, bytes calldata signature) external payable;
}
