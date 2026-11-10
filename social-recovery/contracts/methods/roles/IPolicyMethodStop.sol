// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title IPolicyMethodStop
/// @author defi-wonderland
/// @notice This interface declares the two stop controls of `IPolicyMethodPause` with the same selectors and
///         without its events.
/// @dev `PolicyMethodRoles` implements `pause` and `unpause` against this interface and does not inherit
///      `IPolicyMethodPause`. `Pausable` already declares the `Paused` and `Unpaused` events. A second
///      declaration of the same events would not compile. This interface adds no selector to the method. The
///      canonical docs live in `IPolicyMethodPause`.
interface IPolicyMethodStop {
  /*///////////////////////////////////////////////////////////////
                              LOGIC
  ///////////////////////////////////////////////////////////////*/

  /// @notice Stop this method. Only the pause holder can call it. `IPolicyMethodPause.pause` documents it in full.
  function pause() external;

  /// @notice Lift the stop so that this method's proofs count again. Only the pause holder can call it.
  ///         `IPolicyMethodPause.unpause` documents it in full.
  function unpause() external;
}
