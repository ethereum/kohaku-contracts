// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title IPolicyMethodAdmin
/// @notice The key admin's surface of a method that holds trusted keys. The shipped identity
///         methods implement it. The wallet and passkey methods hold no keys and do not implement
///         it. The key admin is a role of its own, separate from the pause holder of
///         IPolicyMethodPause. Its handover takes the same two steps as OpenZeppelin's
///         Ownable2Step, which the pause holder's role already uses. It narrows that shape in one
///         way. Once the admin renounces, the role stays empty and no caller acts as it.
interface IPolicyMethodAdmin {
  /// @notice The keys changed. Emitted so that off-chain monitoring, if anyone runs it, can alert
  ///         the holders whose rule names this method.
  /// @param _previous The keys trusted before the change.
  /// @param _current The keys trusted from now on.
  event TrustedKeysUpdated(bytes32[] _previous, bytes32[] _current);

  /// @notice A transfer of the key admin role was offered. Emitted so that off-chain monitoring,
  ///         if anyone runs it, can alert the holders whose rule names this method. The offer is
  ///         the one window in which the handover is visible before the new admin can set a key
  ///         and forge proofs with it.
  /// @param _current The admin offering the role.
  /// @param _pending The address the role is offered to.
  event AdminTransferOffered(address indexed _current, address indexed _pending);

  /// @notice The key admin role changed hands.
  /// @param _previous The admin before the handover.
  /// @param _current The admin after the handover.
  event AdminTransferred(address indexed _previous, address indexed _current);

  /// @notice The admin renounced the role. The keys set until now stay the keys forever.
  /// @param _previous The admin that renounced.
  event AdminRenounced(address indexed _previous);

  /// @notice The caller may not act as the key admin, or may not accept a transfer nobody offered
  ///         it. Once the role is renounced, every caller is refused, the zero address included.
  /// @param _account The caller refused.
  error PolicyMethodRoles_AdminUnauthorizedAccount(address _account);

  /// @notice The zero address was given as the initial key admin.
  /// @param _admin The admin refused.
  error PolicyMethodRoles_AdminInvalidAdmin(address _admin);

  /// @notice Replace the keys this method trusts. Only the admin may call it. Each method fixes
  ///         the number and layout of keys it accepts, and any other input reverts.
  /// @param _trustedKeys The keys this method trusts from now on.
  function setTrustedKeys(bytes32[] calldata _trustedKeys) external;

  /// @notice Offer the key admin role to another address. The handover takes two steps, the shape
  ///         OpenZeppelin's Ownable2Step gives ownership. The named address becomes the admin
  ///         only by accepting. So a mistyped address strands nothing, and a compromised admin
  ///         key can be replaced without freezing the keys. Only the admin may call it.
  /// @param _newAdmin The address the role is offered to.
  function transferAdmin(address _newAdmin) external;

  /// @notice Accept a transfer offered to the caller.
  function acceptAdmin() external;

  /// @notice Give up the key admin role for good, the way OpenZeppelin's Ownable renounces
  ///         ownership. trustedParties then reports nobody in that role. The call leaves the
  ///         pause untouched, since the pause is a separate role behind a separate function. It
  ///         is meant for a method whose stack has stopped rotating keys. It is the last resort,
  ///         not the answer to a key that needs replacing.
  function renounceAdmin() external;

  /// @notice The pending admin, or address(0) when no transfer is open.
  /// @return _pendingAdmin The address one acceptance away from the key admin role.
  function pendingAdmin() external view returns (address _pendingAdmin);
}
