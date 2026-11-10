// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';
import {IZkPassportMethod} from 'contracts/methods/zkpassport/IZkPassportMethod.sol';
import {IZkPassportRootVerifier} from 'contracts/methods/zkpassport/IZkPassportRootVerifier.sol';
import {IZkPassportVerifierHelper} from 'contracts/methods/zkpassport/IZkPassportVerifierHelper.sol';
import {PolicyMethodRoles} from 'contracts/methods/roles/PolicyMethodRoles.sol';

/// @title ZkPassportMethod
/// @author defi-wonderland
/// @notice A policy method that approves a digest with a zkPassport proof. The proof must be made with one
///         specific identity document and must bind the digest as its custom data. The method checks it through
///         zkPassport's root verifier, fixed at deployment, and never accepts development proofs.
/// @dev The trusted keys are exactly eight words, in this order, each address left-padded to one word:
///      0. the accepted zkPassport version,
///      1. the root verifier address,
///      2. the reviewed sub-verifier address for that version,
///      3. the expected verifier helper address, which `verify` requires the root verifier to return,
///      4. the root registry address,
///      5. the last reviewed root admin,
///      6. zkPassport's last reviewed root guardian, the one word that may be zero,
///      7. the last reviewed sub-verifier admin.
///      The root verifier in word 1 is fixed at deployment: the constructor takes it from the initial list, and
///      every later list must repeat it. A root verifier the key admin could replace would let the admin point
///      the method at a contract of its own that answers valid for any identifier, and so forge every credential
///      whose config it knows. zkPassport moves its versions behind one root verifier address, so the fixed
///      address costs nothing at a version change: the admin still moves the accepted version and the helper.
///      The word stays in the list so that `trustedParties` still reports the root verifier, which is a party.
///      `verify` reads words 0 and 3 and calls the fixed root verifier. The other five words record the outside
///      parties the verdict depends on, as last reviewed. `trustedParties` reports them, so a deployment check
///      can compare them with the live upstream contracts. A version word holds major, minor and patch as three
///      big-endian `uint16` values in its first six bytes, and zero in the rest.
///      The config is `abi.encode(bytes32 uniqueIdentifier, string domain, string scope, uint256
///      validityPeriodInSeconds)`. It names no zkPassport version. The method routes every proof with the
///      accepted version in word 0, so a change of the accepted version keeps committed configs working. The
///      proof is `abi.encode(ProofVerificationData proofVerificationData, bytes committedInputs)`.
contract ZkPassportMethod is PolicyMethodRoles, IZkPassportMethod {
  /*///////////////////////////////////////////////////////////////
                              CONSTANTS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The number of trusted-key words this method accepts.
  uint256 private constant _TRUSTED_KEY_COUNT = 8;

  /// @notice The position of the accepted version among the trusted keys.
  uint256 private constant _VERSION_KEY = 0;

  /// @notice The position of the root verifier address among the trusted keys.
  uint256 private constant _ROOT_VERIFIER_KEY = 1;

  /// @notice The position of the expected address of zkPassport's verifier helper among the trusted keys.
  uint256 private constant _VERIFIER_HELPER_KEY = 3;

  /// @notice The position of zkPassport's root guardian among the trusted keys. This word may be zero, because
  ///         the upstream root verifier may run without a root guardian.
  uint256 private constant _ROOT_GUARDIAN_KEY = 6;

  /// @notice How far from the end of the public inputs the nullifier type sits. The reviewed sub-verifier puts
  ///         the nullifier type, the scoped nullifier and the OPRF key hash last, in that order.
  uint256 private constant _NULLIFIER_TYPE_FROM_END = 3;

  /// @notice The byte length of a digest. Its text rendering holds two characters per byte after the 0x prefix.
  uint256 private constant _DIGEST_LENGTH = 32;

  /// @notice The lowercase hexadecimal digits, indexed by the value of the half byte each one renders.
  bytes16 private constant _HEX_DIGITS = '0123456789abcdef';

  /*///////////////////////////////////////////////////////////////
                           STATE VARIABLES
  ///////////////////////////////////////////////////////////////*/

  /// @notice zkPassport's root verifier, which `verify` calls. The constructor takes it from word 1 of the
  ///         validated initial list, and `_validateTrustedKeys` refuses every later list whose word 1 differs.
  /// @dev Only the constructor writes it, so it is fixed at deployment. It is a storage variable and not an
  ///      immutable so that the method's runtime code stays the compiled runtime code, which the deployment
  ///      check compares by code hash.
  address private _rootVerifier;

  /*///////////////////////////////////////////////////////////////
                             CONSTRUCTOR
  ///////////////////////////////////////////////////////////////*/

  /// @notice Deploy the method with its two roles and its first eight trusted-key words.
  /// @dev The initial keys pass through `_validateTrustedKeys`, the same check every later key update passes. The
  ///      initial list fixes the root verifier and passes every other rule a later list must pass. The base
  ///      constructor validates and stores the list before this body runs, so the root verifier is read from the
  ///      stored, validated list. The root verifier is one of the key words, so the constructor takes no separate
  ///      verifier argument.
  /// @param _initialOwner The pause holder.
  /// @param _initialAdmin The key admin.
  /// @param _initialKeys The eight trusted-key words, in the order the contract documents.
  constructor(address _initialOwner, address _initialAdmin, bytes32[] memory _initialKeys)
    PolicyMethodRoles(_initialOwner, _initialAdmin, _initialKeys, 'method-zkpassport', '1.0.0')
  {
    _rootVerifier = _toAddress(_trustedKey(_ROOT_VERIFIER_KEY));
  }

  /*///////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPolicyMethod
  /// @dev It answers the magic value only when zkPassport's root verifier accepts the proof, the proof was made
  ///      with the identity document the config commits to, and the proof binds this digest as its custom data.
  ///      Any other proof gets zero, and a config whose identifier is zero gets zero before any call. The proof
  ///      is routed with the accepted version from the trusted keys, never with a version from the config. Each
  ///      early return leaves `_magicValue` at zero, which the manager reads as a refusal; only the last line
  ///      sets it. A config or proof that does not decode reverts, as does a failing call to the root verifier
  ///      or the verifier helper. It never reads this method's own pause, because only the manager acts on a
  ///      stop.
  function verify(bytes calldata _config, bytes32 _digest, bytes calldata _proof)
    external
    view
    returns (bytes4 _magicValue)
  {
    bytes32 _acceptedVersion = _trustedKey(_VERSION_KEY);
    (bytes32 _uniqueIdentifier, IZkPassportRootVerifier.ServiceConfig memory _serviceConfig) = _decodeConfig(_config);
    if (_uniqueIdentifier == bytes32(0)) return _magicValue;

    IZkPassportRootVerifier.ProofVerificationParams memory _params =
      _buildParams(_acceptedVersion, _proof, _serviceConfig);
    (bool _valid, bytes32 _returnedIdentifier, IZkPassportVerifierHelper _verifierHelper) =
      IZkPassportRootVerifier(_rootVerifier).verify(_params);
    if (
      !_valid || _returnedIdentifier != _uniqueIdentifier
        || address(_verifierHelper) != _toAddress(_trustedKey(_VERIFIER_HELPER_KEY))
    ) return _magicValue;
    // The nullifier type is the third public input from the end, and only the non-salted type, zero, passes. A
    // list too short to hold it fails.
    bytes32[] memory _publicInputs = _params.proofVerificationData.publicInputs;
    if (
      _publicInputs.length < _NULLIFIER_TYPE_FROM_END
        || _publicInputs[_publicInputs.length - _NULLIFIER_TYPE_FROM_END] != bytes32(0)
    ) return _magicValue;
    IZkPassportVerifierHelper.BoundData memory _boundData = _verifierHelper.getBoundData(_params.committedInputs);
    // The custom data must equal the digest's text rendering exactly: 0x then sixty four lowercase hexadecimal
    // characters, high half of each byte first. Any other rendering of the same digest fails.
    bytes memory _rendering = new bytes(2 + 2 * _DIGEST_LENGTH);
    _rendering[0] = '0';
    _rendering[1] = 'x';
    for (uint256 _i; _i < _DIGEST_LENGTH; ++_i) {
      uint8 _value = uint8(_digest[_i]);
      _rendering[2 + 2 * _i] = _HEX_DIGITS[_value >> 4];
      _rendering[3 + 2 * _i] = _HEX_DIGITS[_value & 0x0f];
    }
    if (keccak256(bytes(_boundData.customData)) != keccak256(_rendering)) return _magicValue;

    _magicValue = IPolicyMethod.verify.selector;
  }

  /*///////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Refuse a trusted-key list the method could not rely on. The deployment and every key update pass
  ///         through this check.
  /// @dev Every word but zkPassport's root guardian is either read by `verify` or declared as a reviewed party,
  ///      so a zero there is a mistake. The root guardian may be zero because the upstream root verifier may have
  ///      none.
  ///      Every word but the version is an address word. An address word with a nonzero upper byte is refused
  ///      instead of truncated, so the stored word is exactly the address that was declared. The version word
  ///      must be canonical, so that one zkPassport release has exactly one word.
  ///      Word 1 must equal the root verifier fixed at deployment. The constructor's call runs before the fixed
  ///      root verifier is written, when it reads as zero, and then the check is skipped: that call validates the
  ///      list that fixes it. A validated word 1 is never zero, so after construction the check always applies.
  /// @param _keys The candidate trusted keys.
  function _validateTrustedKeys(bytes32[] memory _keys) internal view override {
    require(_keys.length == _TRUSTED_KEY_COUNT, ZkPassportMethod_InvalidTrustedKeysLength(_keys.length));
    for (uint256 _i; _i < _TRUSTED_KEY_COUNT; ++_i) {
      bytes32 _word = _keys[_i];
      require(_word != bytes32(0) || _i == _ROOT_GUARDIAN_KEY, ZkPassportMethod_ZeroTrustedKey(_i));
      require(_i != _VERSION_KEY || uint256(_word) << 48 == 0, ZkPassportMethod_VersionWordNotCanonical(_word));
      require(_i == _VERSION_KEY || uint256(_word) >> 160 == 0, ZkPassportMethod_AddressWordNotClean(_i, _word));
    }
    bytes32 _fixed = bytes32(uint256(uint160(_rootVerifier)));
    require(
      _fixed == bytes32(0) || _keys[_ROOT_VERIFIER_KEY] == _fixed,
      ZkPassportMethod_RootVerifierChanged(_fixed, _keys[_ROOT_VERIFIER_KEY])
    );
  }

  /*///////////////////////////////////////////////////////////////
                          PRIVATE FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Decode a config into its identifier and the service configuration the root verifier takes. The
  ///         config names no version. The service configuration always refuses development proofs.
  /// @param _config The ABI-encoded config.
  /// @return _uniqueIdentifier The identifier the proof must derive.
  /// @return _serviceConfig The validity period, domain and scope, with `devMode` false.
  function _decodeConfig(bytes calldata _config)
    private
    pure
    returns (bytes32 _uniqueIdentifier, IZkPassportRootVerifier.ServiceConfig memory _serviceConfig)
  {
    string memory _domain;
    string memory _scope;
    uint256 _validityPeriodInSeconds;
    (_uniqueIdentifier, _domain, _scope, _validityPeriodInSeconds) =
      abi.decode(_config, (bytes32, string, string, uint256));
    _serviceConfig = IZkPassportRootVerifier.ServiceConfig({
      validityPeriodInSeconds: _validityPeriodInSeconds, domain: _domain, scope: _scope, devMode: false
    });
  }

  /// @notice Decode a proof and assemble the root verifier's parameters around it.
  /// @param _acceptedVersion The accepted zkPassport version, which selects the proof route.
  /// @param _proof The ABI-encoded proof data and committed inputs.
  /// @param _serviceConfig The service configuration the config names, with development proofs refused.
  /// @return _params The parameters the root verifier's `verify` takes.
  function _buildParams(
    bytes32 _acceptedVersion,
    bytes calldata _proof,
    IZkPassportRootVerifier.ServiceConfig memory _serviceConfig
  ) private pure returns (IZkPassportRootVerifier.ProofVerificationParams memory _params) {
    (IZkPassportRootVerifier.ProofVerificationData memory _proofVerificationData, bytes memory _committedInputs) =
      abi.decode(_proof, (IZkPassportRootVerifier.ProofVerificationData, bytes));
    _params = IZkPassportRootVerifier.ProofVerificationParams({
      version: _acceptedVersion,
      proofVerificationData: _proofVerificationData,
      committedInputs: _committedInputs,
      serviceConfig: _serviceConfig
    });
  }

  /// @notice Read a left-padded trusted-key word as an address.
  /// @param _word The trusted-key word.
  /// @return _account The address held in the word's low twenty bytes.
  function _toAddress(bytes32 _word) private pure returns (address _account) {
    _account = address(uint160(uint256(_word)));
  }
}
