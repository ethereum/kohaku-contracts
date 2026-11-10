// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PolicyMethodRoles} from 'contracts/methods/roles/PolicyMethodRoles.sol';

/// @notice A subclass of the roles base for tests only, whose key validation hook accepts any list and then
///         overwrites the first word of the list it was handed with SCRIBBLE. If the base stored the same list it
///         handed the hook, the stored keys would carry SCRIBBLE instead of the words the caller gave.
contract MethodRolesScribblingHarness is PolicyMethodRoles {
  /*///////////////////////////////////////////////////////////////
                          STATE VARIABLES
  ///////////////////////////////////////////////////////////////*/

  /// @notice The word the hook writes into the first position of its argument.
  bytes32 public constant SCRIBBLE = keccak256('method-roles.scribbling-harness.scribble');

  /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ///////////////////////////////////////////////////////////////*/

  /// @dev Hands every argument to the roles base unchanged.
  constructor(
    address _initialOwner,
    address _initialAdmin,
    bytes32[] memory _initialKeys,
    string memory _moduleName,
    string memory _moduleVersion
  ) PolicyMethodRoles(_initialOwner, _initialAdmin, _initialKeys, _moduleName, _moduleVersion) {}

  /*///////////////////////////////////////////////////////////////
                         EXTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @notice A verifier that approves nothing, since the roles base leaves verify to each method.
  function verify(bytes calldata, bytes32, bytes calldata) external pure override returns (bytes4 _magicValue) {
    _magicValue = bytes4(0);
  }

  /*///////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @dev Accepts any list, then writes SCRIBBLE into the first word of the list it was handed.
  function _validateTrustedKeys(bytes32[] memory _keys) internal pure override {
    if (_keys.length != 0) _keys[0] = SCRIBBLE;
  }
}
