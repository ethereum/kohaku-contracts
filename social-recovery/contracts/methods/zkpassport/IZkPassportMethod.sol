// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title IZkPassportMethod
/// @author defi-wonderland
/// @notice The errors the zkPassport method raises when it refuses a trusted-key list. Callers and tests name
///         them through this interface.
interface IZkPassportMethod {
  /*///////////////////////////////////////////////////////////////
                               ERRORS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The trusted-key list does not hold exactly eight words.
  /// @param _length The refused list's length.
  error ZkPassportMethod_InvalidTrustedKeysLength(uint256 _length);

  /// @notice A trusted-key word other than zkPassport's root guardian is zero.
  /// @param _index The position of the zero word in the refused list.
  error ZkPassportMethod_ZeroTrustedKey(uint256 _index);

  /// @notice A trusted-key word the method reads as an address has a nonzero byte in its upper twelve bytes.
  ///         The method refuses such a word instead of truncating it, as the ABI decoder does for an address.
  /// @param _index The position of the refused word in the refused list.
  /// @param _word The refused word.
  error ZkPassportMethod_AddressWordNotClean(uint256 _index, bytes32 _word);

  /// @notice The version word has a nonzero byte after its first six. A canonical version word holds major,
  ///         minor and patch as three big-endian `uint16` values in its first six bytes and zero after them.
  /// @param _word The refused version word.
  error ZkPassportMethod_VersionWordNotCanonical(bytes32 _word);

  /// @notice The trusted-key list names another root verifier than the one fixed at deployment. The root
  ///         verifier is the one word the key admin cannot replace: a root verifier of the admin's choosing could
  ///         answer valid for any identifier and so forge every credential whose config the admin knows.
  ///         zkPassport moves its versions behind one root verifier address, so a fixed address costs nothing at
  ///         a version change.
  /// @param _fixed The root verifier word fixed at deployment.
  /// @param _proposed The refused list's root verifier word.
  error ZkPassportMethod_RootVerifierChanged(bytes32 _fixed, bytes32 _proposed);
}
