// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title IZkPassportVerifierHelper
/// @author defi-wonderland
/// @notice The one call this method makes on zkPassport's verifier helper, which the root verifier returns
///         beside a verdict.
interface IZkPassportVerifierHelper {
  /*///////////////////////////////////////////////////////////////
                              STRUCTS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The data a zkPassport bind proof commits to, in the field order the upstream verifier helper returns.
  /// @param senderAddress The user address the proof binds.
  /// @param chainId The chain id the proof binds.
  /// @param customData The free text the proof binds. This method requires the digest's hexadecimal rendering.
  struct BoundData {
    address senderAddress;
    uint256 chainId;
    string customData;
  }

  /*///////////////////////////////////////////////////////////////
                              LOGIC
  ///////////////////////////////////////////////////////////////*/

  /// @notice Reads the data a bind proof commits to from its committed inputs.
  /// @param committedInputs The preimages of the proof's parameter commitments.
  /// @return boundData The sender address, chain id and custom data the proof binds.
  function getBoundData(bytes calldata committedInputs) external view returns (BoundData memory boundData);
}
