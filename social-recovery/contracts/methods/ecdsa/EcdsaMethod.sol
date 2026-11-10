// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';

/// @title EcdsaMethod
/// @author defi-wonderland
/// @notice The wallet method. It checks that a guardian's wallet signed the EIP-712 digest and no other signed form.
/// @dev The config is `abi.encode(address guardian)`, which is one ABI word. The proof is the guardian's signature
///      over the digest as raw bytes, not `abi.encode(bytes signature)`. OpenZeppelin's SignatureChecker picks one
///      path from whether the guardian's address has code at verification time. An address with no code takes ECDSA
///      recovery: the proof is the 65-byte `r || s || v` signature, and any other length is refused. An address with
///      code takes the ERC-1271 path: the proof goes unchanged to the guardian's `isValidSignature`, so its length
///      and format are whatever that contract accepts. The library never falls back from one path to the other. The
///      method holds no storage, no trusted key and no pause.
contract EcdsaMethod is IPolicyMethod {
  /*///////////////////////////////////////////////////////////////
                          STATE VARIABLES
  ///////////////////////////////////////////////////////////////*/

  /// @notice The module's human-readable name.
  string internal constant _NAME = 'method-ecdsa';

  /// @notice The module's semantic version.
  string internal constant _VERSION = '1.0.0';

  /*///////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPolicyMethod
  /// @dev A config of any length but 32 bytes returns zero. A 32-byte config whose upper twelve bytes are not
  ///      zero is not a clean address, and the ABI decoder reverts on it instead of returning zero. A proof the
  ///      guardian did not make returns zero. The manager reads a revert from a method as a rejection, the same
  ///      as a zero answer, so the two outcomes refuse the proof alike.
  function verify(bytes calldata _config, bytes32 _digest, bytes calldata _proof)
    external
    view
    returns (bytes4 _magicValue)
  {
    // The config must be exactly one ABI word. The method refuses any other length before the library runs.
    if (_config.length != 32) return _magicValue;
    address _guardian = abi.decode(_config, (address));
    if (SignatureChecker.isValidSignatureNowCalldata(_guardian, _digest, _proof)) {
      _magicValue = IPolicyMethod.verify.selector;
    }
  }

  /// @inheritdoc IPolicyMethod
  function trustedParties()
    external
    pure
    returns (
      address _admin,
      address _pendingAdmin,
      bytes32[] memory _trustedKeys,
      address _pauseHolder,
      address _pendingPauseHolder
    )
  {
    _trustedKeys = new bytes32[](0);
    (_admin, _pendingAdmin, _pauseHolder, _pendingPauseHolder) = (address(0), address(0), address(0), address(0));
  }

  /// @inheritdoc IPolicyMethod
  function supportsInterface(bytes4 _interfaceId) external pure returns (bool _supported) {
    _supported = _interfaceId == type(IPolicyMethod).interfaceId || _interfaceId == type(IERC165).interfaceId;
  }

  /// @inheritdoc IPolicyMethod
  function name() external pure returns (string memory _moduleName) {
    _moduleName = _NAME;
  }

  /// @inheritdoc IPolicyMethod
  function version() external pure returns (string memory _moduleVersion) {
    _moduleVersion = _VERSION;
  }
}
