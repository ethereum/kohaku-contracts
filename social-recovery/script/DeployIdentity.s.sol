// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Script} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';

import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';
import {IPolicyMethodAdmin} from 'interfaces/IPolicyMethodAdmin.sol';
import {IPolicyMethodPause} from 'interfaces/IPolicyMethodPause.sol';

import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {AadhaarMethod} from 'contracts/methods/aadhaar/AadhaarMethod.sol';
import {IAadhaarMethod} from 'contracts/methods/aadhaar/IAadhaarMethod.sol';
import {ZkPassportMethod} from 'contracts/methods/zkpassport/ZkPassportMethod.sol';

/// @title DeployIdentity
/// @author defi-wonderland
/// @notice Deploys the zkPassport method on mainnet or Sepolia, and the Aadhaar method on Sepolia, and checks them
///         before anything is sent.
/// @dev Each method is created directly with its real constructor arguments, with no proxy and no upgrade admin.
///      Every check reads the outside contracts and the deployed methods back from the chain rather than trusting
///      what the script meant to deploy. Each read of an outside answer is a low-level call, so a revert, an empty
///      answer or a malformed one fails with this script's own error rather than with the target's.
contract DeployIdentity is Script, IDeployIdentity {
  /*///////////////////////////////////////////////////////////////
                          STATE VARIABLES
  ///////////////////////////////////////////////////////////////*/

  /// @notice Ethereum mainnet's chain id.
  uint256 internal constant _MAINNET_CHAIN_ID = 1;

  /// @notice Sepolia's chain id.
  uint256 internal constant _SEPOLIA_CHAIN_ID = 11_155_111;

  /// @notice The zkPassport version both chains accept, 0.21.1: major, minor and patch as three big-endian
  ///         uint16 values in the first six bytes, and zero after them.
  bytes32 internal constant _ACCEPTED_VERSION = 0x0000001500010000000000000000000000000000000000000000000000000000;

  /// @notice zkPassport's root verifier, the same address on both chains.
  address internal constant _ROOT_VERIFIER = 0x1D000001000EFD9a6371f4d90bB8920D5431c0D8;

  /// @notice zkPassport's root registry, the same address on both chains.
  address internal constant _ROOT_REGISTRY = 0x1D0000020038d6E40E1d98e09fA1bb3A7DAA8B70;

  /// @notice The reviewed version 0.21.1 sub-verifier on mainnet.
  address internal constant _MAINNET_SUB_VERIFIER = 0xBeAE01953C520A49eE869c02edBE69D6da93D965;

  /// @notice The verifier helper the version 0.21.1 route returns on mainnet.
  address internal constant _MAINNET_VERIFIER_HELPER = 0x1E878E61D565F4c40FC40235D4c4A5FC66Afab2D;

  /// @notice The reviewed version 0.21.1 sub-verifier on Sepolia.
  address internal constant _SEPOLIA_SUB_VERIFIER = 0x77cB76Df1b37644126f8e04caA88356F78A61e47;

  /// @notice The verifier helper the version 0.21.1 route returns on Sepolia.
  address internal constant _SEPOLIA_VERIFIER_HELPER = 0xe8AE97eF2fFF59597D1B6882286754FEC200F3a9;

  /// @notice The Anon Aadhaar Groth16 verifier on Sepolia, the only chain the Aadhaar method ships on.
  address internal constant _SEPOLIA_AADHAAR_VERIFIER = 0xCBd85cd69C4779aA9a7AB9B6D6A9f6FEd61504F0;

  /// @notice The code hash of the Anon Aadhaar Groth16 verifier on Sepolia, read from the chain, so a wrong
  ///         contract at the pinned address is caught even though it has code.
  bytes32 internal constant _SEPOLIA_AADHAAR_VERIFIER_CODEHASH =
    0x7e2982555ebd6cae0492f083ab5bc6d2753249ed2a8b9d1391f643beba23db47;

  /// @notice The hash the pinned Anon Aadhaar circuit computes for UIDAI's current offline e-KYC public key, the
  ///         certificate valid from 2026-02-03 to 2029-02-03. It is the decimal value
  ///         19770349258225098911243612275321727303641256718510179842211794623059325011884.
  bytes32 internal constant _SEPOLIA_AADHAAR_KEY = 0x2bb59f02b2cef412f561eff2f45309427760dc82f1ca12338e890d64d212c7ac;

  /// @notice The public-key hash of the Anon Aadhaar stack's test signing key, whose private half is published.
  /// @dev `testPublicKeyHash` in anon-aadhaar/anon-aadhaar at commit 4dad918761cfb1d7d5ed9918dcd796d0cb23ae82,
  ///      packages/core/src/constants.ts lines 57 and 58, is the decimal value
  ///      15134874015316324267425466444584014077184337590635665158241104437045239495873.
  bytes32 internal constant _AADHAAR_TEST_KEY = 0x217608fddff9ccea4198e5674875e703458f8700115ef34bbee6ae94a3c83cc1;

  /// @notice The public-key hash of UIDAI's expired production key, the certificate valid from 2021-02-26 to
  ///         2024-02-27.
  /// @dev `productionPublicKeyHash` in anon-aadhaar/anon-aadhaar at commit 4dad918761cfb1d7d5ed9918dcd796d0cb23ae82,
  ///      packages/core/src/constants.ts.
  bytes32 internal constant _AADHAAR_UIDAI_2021_KEY =
    0x27ef89612fc4a823b52a334ed4f2a48f8d066d8b3ed2ba5672bb5f531aab61ec;

  /// @notice The public-key hash of UIDAI's expired production key from the certificate
  ///         uidai_offline_publickey_17022026.cer, valid from 2024-02-21 to 2026-02-16.
  bytes32 internal constant _AADHAAR_UIDAI_2024_KEY =
    0x0ff4c3a0af5fb98ae76bfedb5fd93598e030a07302ad42f6a8719f93015bc13f;

  /// @notice The root verifier's read of the sub-verifier it routes a version to.
  /// @dev `getSubVerifier(bytes32 version) returns (address)` in zkpassport/zkpassport-packages at commit
  ///      5f7b5c5eb144b04a6edc5097f99d45f0900d80c4, packages/registry-contracts/src/RootVerifier.sol line 173.
  bytes4 internal constant _GET_SUB_VERIFIER = bytes4(keccak256('getSubVerifier(bytes32)'));

  /// @notice The root verifier's read of the verifier helper it returns for a version.
  /// @dev `getHelper(bytes32 version) returns (address)` at the same commit, RootVerifier.sol line 224.
  bytes4 internal constant _GET_VERIFIER_HELPER = bytes4(keccak256('getHelper(bytes32)'));

  /// @notice The root verifier's read of the root registry it passes to every sub-verifier.
  /// @dev The public variable `rootRegistry` at the same commit, RootVerifier.sol line 27.
  bytes4 internal constant _REGISTRY_GETTER = bytes4(keccak256('rootRegistry()'));

  /// @notice The read of an upstream contract's admin, the same getter on the root verifier and the sub-verifier.
  /// @dev The public variable `admin` at the same commit, RootVerifier.sol line 22 and SubVerifier.sol line 21.
  bytes4 internal constant _ADMIN_GETTER = bytes4(keccak256('admin()'));

  /// @notice The root verifier's read of the root guardian, which can pause the root.
  /// @dev The public variable `guardian` at the same commit, RootVerifier.sol line 23.
  bytes4 internal constant _ROOT_GUARDIAN_GETTER = bytes4(keccak256('guardian()'));

  /// @notice The number of trusted-key words the zkPassport method holds.
  uint256 internal constant _ZKPASSPORT_KEY_COUNT = 8;

  /// @notice The position of the accepted version among the zkPassport words.
  uint256 internal constant _VERSION_WORD = 0;

  /// @notice The position of the root verifier among the zkPassport words.
  uint256 internal constant _ROOT_VERIFIER_WORD = 1;

  /// @notice The position of the sub-verifier among the zkPassport words.
  uint256 internal constant _SUB_VERIFIER_WORD = 2;

  /// @notice The position of the verifier helper among the zkPassport words.
  uint256 internal constant _VERIFIER_HELPER_WORD = 3;

  /// @notice The position of the root registry among the zkPassport words.
  uint256 internal constant _ROOT_REGISTRY_WORD = 4;

  /// @notice The position of the root admin among the zkPassport words.
  uint256 internal constant _ROOT_ADMIN_WORD = 5;

  /// @notice The position of the root guardian among the zkPassport words.
  uint256 internal constant _ROOT_GUARDIAN_WORD = 6;

  /// @notice The position of the sub-verifier admin among the zkPassport words.
  uint256 internal constant _SUB_VERIFIER_ADMIN_WORD = 7;

  /// @notice The size of one ABI word, the only length a single address or bool answer has.
  uint256 internal constant _WORD = 32;

  /// @notice The environment variable that holds the zkPassport method's Safe.
  string internal constant _ZKPASSPORT_METHOD_SAFE_VARIABLE = 'ZKPASSPORT_METHOD_SAFE';

  /// @notice The environment variable that holds the Aadhaar method's Safe.
  string internal constant _AADHAAR_METHOD_SAFE_VARIABLE = 'AADHAAR_METHOD_SAFE';

  /// @notice The environment variable that holds the reviewed root admin.
  string internal constant _ROOT_ADMIN_VARIABLE = 'ZKPASSPORT_ROOT_ADMIN';

  /// @notice The environment variable that holds the reviewed root guardian.
  string internal constant _ROOT_GUARDIAN_VARIABLE = 'ZKPASSPORT_ROOT_GUARDIAN';

  /// @notice The environment variable that holds the reviewed sub-verifier admin.
  string internal constant _SUB_VERIFIER_ADMIN_VARIABLE = 'ZKPASSPORT_SUBVERIFIER_ADMIN';

  /// @notice The environment variable that names the record files instead of the chain id.
  string internal constant _LABEL_VARIABLE = 'DEPLOYMENT_LABEL';

  /// @notice Where the record files live, relative to the project root.
  string internal constant _DEPLOYMENTS_DIR = '/script/deployments/';

  /// @notice The part of a record's file name after its label, which keeps it apart from the demo path's record.
  ///         It starts with a dot, which no label can hold, so no label of either script gives the other's name.
  string internal constant _IDENTITY_SUFFIX = '.identity';

  /// @notice The suffix of the candidate record run writes.
  string internal constant _PENDING_SUFFIX = '.pending.json';

  /// @notice The suffix of the published record confirm writes.
  string internal constant _RECORD_SUFFIX = '.json';

  /// @notice The longest label accepted, in characters.
  uint256 internal constant _MAX_LABEL_LENGTH = 64;

  /*///////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDeployIdentity
  function run() external returns (Deployment memory _deployment) {
    Pins memory _pins = _pinsFor(block.chainid);
    string memory _label = _recordLabel(block.chainid);
    Inputs memory _inputs = _inputsFromEnv(_pins.shipsAadhaar);
    _deployment = _deploy(_pins, _inputs);
    if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
      string memory _dir = string.concat(vm.projectRoot(), _DEPLOYMENTS_DIR);
      vm.createDir(_dir, true);
      vm.writeJson(
        _recordJson(_deployment, _pins, _inputs, block.chainid),
        string.concat(_dir, _label, _IDENTITY_SUFFIX, _PENDING_SUFFIX)
      );
    }
  }

  /// @inheritdoc IDeployIdentity
  function confirm() external returns (Deployment memory _deployment) {
    Pins memory _pins = _pinsFor(block.chainid);
    _deployment = _confirmLabel(_recordLabel(block.chainid), _pins);
  }

  /// @inheritdoc IDeployIdentity
  function confirmLabel(string calldata _label) external returns (Deployment memory _deployment) {
    Pins memory _pins = _pinsFor(block.chainid);
    _deployment = _confirmLabel(_labelFor(true, _label, block.chainid), _pins);
  }

  /// @inheritdoc IDeployIdentity
  function deploy(Pins calldata _pins, Inputs calldata _inputs) external returns (Deployment memory _deployment) {
    _deployment = _deploy(_pins, _inputs);
  }

  /// @inheritdoc IDeployIdentity
  function recordJson(Deployment calldata _deployment, Pins calldata _pins, Inputs calldata _inputs, uint256 _chainId)
    external
    returns (string memory _json)
  {
    _json = _recordJson(_deployment, _pins, _inputs, _chainId);
  }

  /// @inheritdoc IDeployIdentity
  function inputsFromEnv(bool _shipsAadhaar) external view returns (Inputs memory _inputs) {
    _inputs = _inputsFromEnv(_shipsAadhaar);
  }

  /// @inheritdoc IDeployIdentity
  function checkCode(Pins calldata _pins) external view {
    _checkCode(_pins);
  }

  /// @inheritdoc IDeployIdentity
  function checkZkPassportKeys(bytes32[] calldata _words) external view {
    _checkZkPassportKeys(_words);
  }

  /// @inheritdoc IDeployIdentity
  function checkDeployment(Deployment calldata _deployment, Pins calldata _pins, Inputs calldata _inputs)
    external
    view
  {
    _checkDeployment(_deployment, _pins, _inputs);
  }

  /// @inheritdoc IDeployIdentity
  function recordLabel(uint256 _chainId) external view returns (string memory _label) {
    _label = _recordLabel(_chainId);
  }

  /// @inheritdoc IDeployIdentity
  function pinsFor(uint256 _chainId) external pure returns (Pins memory _pins) {
    _pins = _pinsFor(_chainId);
  }

  /// @inheritdoc IDeployIdentity
  function checkInputs(Inputs calldata _inputs, bool _shipsAadhaar) external pure {
    _checkInputs(_inputs, _shipsAadhaar);
  }

  /// @inheritdoc IDeployIdentity
  function zkPassportKeys(Pins calldata _pins, Inputs calldata _inputs)
    external
    pure
    returns (bytes32[] memory _words)
  {
    _words = _zkPassportKeys(_pins, _inputs);
  }

  /// @inheritdoc IDeployIdentity
  function checkAadhaarKey(bytes32 _key) external pure {
    _checkAadhaarKey(_key);
  }

  /// @inheritdoc IDeployIdentity
  function labelFor(bool _isSet, string calldata _value, uint256 _chainId)
    external
    pure
    returns (string memory _label)
  {
    _label = _labelFor(_isSet, _value, _chainId);
  }

  /*///////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Checks the inputs and the chain, deploys the methods in one broadcast and checks what was deployed.
  /// @dev forge refuses a script's calls to its own external functions, so the entry points and this body share
  ///      internal checks rather than calling one another. Every check that needs nothing deployed runs before the
  ///      broadcast starts, so a failing one reverts the script before any creation. The checks over the deployment
  ///      run after the broadcast stops, the code check last, so the local copy the code check builds is never
  ///      sent.
  /// @param _pins The table entry to deploy with.
  /// @param _inputs The operator's inputs.
  /// @return _deployment What this run deployed.
  function _deploy(Pins memory _pins, Inputs memory _inputs) internal returns (Deployment memory _deployment) {
    _checkInputs(_inputs, _pins.shipsAadhaar);
    _checkCode(_pins);
    bytes32[] memory _words = _zkPassportKeys(_pins, _inputs);
    _checkZkPassportKeys(_words);
    if (_pins.shipsAadhaar) _checkAadhaarKey(_pins.aadhaarKey);

    vm.startBroadcast();
    _deployment.zkPassportMethod =
      IPolicyMethod(address(new ZkPassportMethod(_inputs.zkPassportMethodSafe, _inputs.zkPassportMethodSafe, _words)));
    if (_pins.shipsAadhaar) {
      _deployment.aadhaarMethod = IPolicyMethod(
        address(
          new AadhaarMethod(
            _inputs.aadhaarMethodSafe, _inputs.aadhaarMethodSafe, _aadhaarKeys(_pins.aadhaarKey), _pins.aadhaarVerifier
          )
        )
      );
    }
    vm.stopBroadcast();

    _checkDeployment(_deployment, _pins, _inputs);
    _checkKitCode(_deployment, _pins, _inputs);
  }

  /// @notice Publishes the candidate record a label names, once the chain confirms it.
  /// @dev confirm and confirmLabel resolve this chain's table before they read the label, so an unsupported chain
  ///      stops with DeployIdentity_UnsupportedChain before anything else, and the label is already valid when it
  ///      arrives here. The two Safes and the three role words come from the record, since they are inputs no
  ///      table holds, and every check runs again with them. Every check runs before anything is written. The published
  ///      record is rebuilt from the values the checks read, never copied from the candidate's text, so a key no
  ///      check read never reaches it.
  /// @param _label The label that names the candidate and the published record.
  /// @param _pins This chain's table entry.
  /// @return _deployment The deployment the record names.
  function _confirmLabel(string memory _label, Pins memory _pins) internal returns (Deployment memory _deployment) {
    string memory _base = string.concat(vm.projectRoot(), _DEPLOYMENTS_DIR, _label, _IDENTITY_SUFFIX);
    string memory _pendingPath = string.concat(_base, _PENDING_SUFFIX);
    string memory _json = vm.readFile(_pendingPath);

    uint256 _recordedChainId = vm.parseJsonUint(_json, '.chainId');
    require(_recordedChainId == block.chainid, DeployIdentity_RecordChainMismatch(_recordedChainId, block.chainid));

    bytes32[] memory _words = vm.parseJsonBytes32Array(_json, '.zkPassportKeys');
    require(_words.length == _ZKPASSPORT_KEY_COUNT, DeployIdentity_WordCount(_words.length));
    Inputs memory _inputs = Inputs({
      zkPassportMethodSafe: vm.parseJsonAddress(_json, '.zkPassportMethodSafe'),
      aadhaarMethodSafe: vm.parseJsonAddress(_json, '.aadhaarMethodSafe'),
      rootAdmin: _toAddress(_words[_ROOT_ADMIN_WORD]),
      rootGuardian: _toAddress(_words[_ROOT_GUARDIAN_WORD]),
      subVerifierAdmin: _toAddress(_words[_SUB_VERIFIER_ADMIN_WORD])
    });

    _checkInputs(_inputs, _pins.shipsAadhaar);
    if (!_pins.shipsAadhaar) {
      require(_inputs.aadhaarMethodSafe == address(0), DeployIdentity_RecordMismatch('aadhaarMethodSafe'));
    }

    _deployment.zkPassportMethod = IPolicyMethod(_requireDeployed(vm.parseJsonAddress(_json, '.zkPassportMethod')));
    address _recordedAadhaarMethod = vm.parseJsonAddress(_json, '.aadhaarMethod');
    if (_pins.shipsAadhaar) {
      _deployment.aadhaarMethod = IPolicyMethod(_requireDeployed(_recordedAadhaarMethod));
    } else {
      require(_recordedAadhaarMethod == address(0), DeployIdentity_NotDeployed(_recordedAadhaarMethod));
    }

    _requireRecordedPins(_json, _words, _pins, _inputs);
    _checkCode(_pins);
    _checkZkPassportKeys(_words);
    if (_pins.shipsAadhaar) _checkAadhaarKey(_pins.aadhaarKey);
    _checkDeployment(_deployment, _pins, _inputs);
    _checkKitCode(_deployment, _pins, _inputs);

    vm.writeJson(_recordJson(_deployment, _pins, _inputs, block.chainid), string.concat(_base, _RECORD_SUFFIX));
    vm.removeFile(_pendingPath);
  }

  /// @notice Requires each deployed method to run exactly the kit's code. The other checks read answers a contract
  ///         chooses, so a contract written to give the same answers would pass them. Only the code hash ties an
  ///         address to the code that was reviewed.
  /// @dev The zkPassport method holds no immutable, so its code is the compiled runtime code. The Aadhaar method
  ///      holds its verifier as an immutable, so its expected code is that of a local copy built with the table's
  ///      verifier. The roles and the key are storage, not code, so the copy takes the deployment's own. No
  ///      broadcast is active here, so the copy is never sent.
  /// @param _deployment The deployment to check.
  /// @param _pins The table entry it was deployed with.
  /// @param _inputs The operator's inputs it was deployed with.
  function _checkKitCode(Deployment memory _deployment, Pins memory _pins, Inputs memory _inputs) internal {
    _requireKitCode(
      'zkPassportMethod', address(_deployment.zkPassportMethod), keccak256(type(ZkPassportMethod).runtimeCode)
    );
    if (_pins.shipsAadhaar) {
      AadhaarMethod _copy = new AadhaarMethod(
        _inputs.aadhaarMethodSafe, _inputs.aadhaarMethodSafe, _aadhaarKeys(_pins.aadhaarKey), _pins.aadhaarVerifier
      );
      _requireKitCode('aadhaarMethod', address(_deployment.aadhaarMethod), address(_copy).codehash);
    }
  }

  /// @notice Builds the record of one deployment.
  /// @param _deployment What the run deployed.
  /// @param _pins The table entry it deployed with.
  /// @param _inputs The operator's inputs it deployed with.
  /// @param _chainId The chain the deployment lives on.
  /// @return _json The record.
  function _recordJson(Deployment memory _deployment, Pins memory _pins, Inputs memory _inputs, uint256 _chainId)
    internal
    returns (string memory _json)
  {
    string memory _key = 'identityDeployment';
    vm.serializeUint(_key, 'chainId', _chainId);
    vm.serializeAddress(_key, 'zkPassportMethod', address(_deployment.zkPassportMethod));
    vm.serializeAddress(_key, 'aadhaarMethod', address(_deployment.aadhaarMethod));
    vm.serializeAddress(_key, 'zkPassportMethodSafe', _inputs.zkPassportMethodSafe);
    vm.serializeAddress(_key, 'aadhaarMethodSafe', _inputs.aadhaarMethodSafe);
    vm.serializeBytes32(_key, 'zkPassportKeys', _zkPassportKeys(_pins, _inputs));
    vm.serializeAddress(_key, 'aadhaarVerifier', _pins.aadhaarVerifier);
    vm.serializeBytes32(_key, 'aadhaarVerifierCodehash', _pins.aadhaarVerifierCodehash);
    _json = vm.serializeBytes32(_key, 'aadhaarKey', _pins.aadhaarKey);
  }

  /// @notice Reads the inputs from the environment and checks them. The Aadhaar method's Safe is read only where
  ///         the chain deploys that method, and stays the zero address elsewhere.
  /// @param _shipsAadhaar Whether the chain deploys the Aadhaar method.
  /// @return _inputs The inputs read.
  function _inputsFromEnv(bool _shipsAadhaar) internal view returns (Inputs memory _inputs) {
    _inputs.zkPassportMethodSafe = _requiredAddress(_ZKPASSPORT_METHOD_SAFE_VARIABLE);
    if (_shipsAadhaar) _inputs.aadhaarMethodSafe = _requiredAddress(_AADHAAR_METHOD_SAFE_VARIABLE);
    _inputs.rootAdmin = _requiredAddress(_ROOT_ADMIN_VARIABLE);
    _inputs.rootGuardian = _requiredAddress(_ROOT_GUARDIAN_VARIABLE);
    _inputs.subVerifierAdmin = _requiredAddress(_SUB_VERIFIER_ADMIN_VARIABLE);
    _checkInputs(_inputs, _shipsAadhaar);
  }

  /// @notice Reads one address from the environment, refusing a variable that is unset or empty.
  /// @dev An unset variable must never read as the zero address, since the zero address is a meaningful value
  ///      for the root guardian. A value that is set but is not an address stops the script with forge's own
  ///      parse error.
  /// @param _name The variable's name.
  /// @return _value The address it holds.
  function _requiredAddress(string memory _name) internal view returns (address _value) {
    string memory _raw = vm.envOr(_name, string(''));
    require(bytes(_raw).length != 0, DeployIdentity_MissingInput(_name));
    _value = vm.parseAddress(_raw);
  }

  /// @notice Requires each pinned outside contract to have code on this chain, and the Aadhaar verifier, where the
  ///         chain ships it, to have the pinned code. Its address alone would let a wrong contract with code pass.
  /// @param _pins The table entry.
  function _checkCode(Pins memory _pins) internal view {
    _requireCode(_pins.rootVerifier);
    _requireCode(_pins.subVerifier);
    _requireCode(_pins.verifierHelper);
    _requireCode(_pins.rootRegistry);
    if (_pins.shipsAadhaar) {
      address _verifier = _pins.aadhaarVerifier;
      _requireCode(_verifier);
      bytes32 _codehash = _verifier.codehash;
      require(
        _codehash == _pins.aadhaarVerifierCodehash,
        DeployIdentity_AadhaarVerifierCodehashMismatch(_verifier, _pins.aadhaarVerifierCodehash, _codehash)
      );
    }
  }

  /// @notice Requires one address to have code.
  /// @param _target The address.
  function _requireCode(address _target) internal view {
    require(_target.code.length != 0, DeployIdentity_NoCode(_target));
  }

  /// @notice Compares the eight zkPassport words with the live root verifier and sub-verifier.
  /// @dev The word count and every address word are checked before any read. The root verifier word names the
  ///      contract every read goes to, so a truncated one would call another address. An address word with bits
  ///      above its twenty address bytes fails as not clean rather than as a mismatch, since a mismatch error
  ///      shows only the low twenty bytes and would show two equal addresses. The components are compared before
  ///      the roles, since the sub-verifier whose admin is read is the one the sub-verifier word names, and it
  ///      must be the one the root routes to.
  /// @param _words The eight words.
  function _checkZkPassportKeys(bytes32[] memory _words) internal view {
    require(_words.length == _ZKPASSPORT_KEY_COUNT, DeployIdentity_WordCount(_words.length));
    for (uint256 _index = _ROOT_VERIFIER_WORD; _index < _ZKPASSPORT_KEY_COUNT; ++_index) {
      _requireCleanWord(_index, _words[_index]);
    }
    address _root = _toAddress(_words[_ROOT_VERIFIER_WORD]);
    bytes32 _version = _words[_VERSION_WORD];

    _requireComponent(
      'subVerifier', _words[_SUB_VERIFIER_WORD], _root, abi.encodeWithSelector(_GET_SUB_VERIFIER, _version)
    );
    _requireComponent(
      'verifierHelper', _words[_VERIFIER_HELPER_WORD], _root, abi.encodeWithSelector(_GET_VERIFIER_HELPER, _version)
    );
    _requireComponent('rootRegistry', _words[_ROOT_REGISTRY_WORD], _root, abi.encodeWithSelector(_REGISTRY_GETTER));

    _requireRole('rootAdmin', _words[_ROOT_ADMIN_WORD], _root, abi.encodeWithSelector(_ADMIN_GETTER));
    _requireRole('rootGuardian', _words[_ROOT_GUARDIAN_WORD], _root, abi.encodeWithSelector(_ROOT_GUARDIAN_GETTER));
    _requireRole(
      'subVerifierAdmin',
      _words[_SUB_VERIFIER_ADMIN_WORD],
      _toAddress(_words[_SUB_VERIFIER_WORD]),
      abi.encodeWithSelector(_ADMIN_GETTER)
    );
  }

  /// @notice Requires a live component read to equal its word.
  /// @param _component The component's name, for the error.
  /// @param _expected The word the read must equal.
  /// @param _target The contract read.
  /// @param _callData The read.
  function _requireComponent(string memory _component, bytes32 _expected, address _target, bytes memory _callData)
    internal
    view
  {
    (bool _read, address _actual) = _readAddress(_target, _callData);
    require(
      _read && _toWord(_actual) == _expected,
      DeployIdentity_ComponentMismatch(_component, _toAddress(_expected), _actual)
    );
  }

  /// @notice Requires a live role read to equal its reviewed word.
  /// @dev A failed read fails even when the word is zero, so a root guardian that cannot be read never passes
  ///      as no root guardian.
  /// @param _role The role's name, for the error.
  /// @param _expected The word the read must equal.
  /// @param _target The contract read.
  /// @param _callData The read.
  function _requireRole(string memory _role, bytes32 _expected, address _target, bytes memory _callData) internal view {
    (bool _read, address _actual) = _readAddress(_target, _callData);
    require(_read && _toWord(_actual) == _expected, DeployIdentity_RoleMismatch(_role, _toAddress(_expected), _actual));
  }

  /// @notice Reads one address from a contract with a low-level static call.
  /// @dev The answer counts only when the call succeeded and returned exactly one word whose upper twelve bytes
  ///      are zero. A revert, an empty answer (what an address with no code gives) or any other answer is a
  ///      failed read and reports address(0).
  /// @param _target The contract read.
  /// @param _callData The read.
  /// @return _read Whether the read gave a well-formed address.
  /// @return _value The address read, or address(0) when the read failed.
  function _readAddress(address _target, bytes memory _callData) internal view returns (bool _read, address _value) {
    (bool _success, bytes memory _answer) = _target.staticcall(_callData);
    if (_success && _answer.length == _WORD) {
      if (abi.decode(_answer, (uint256)) >> 160 == 0) {
        _read = true;
        _value = abi.decode(_answer, (address));
      }
    }
  }

  /// @notice Runs the checks over the deployed methods: the zkPassport method's first, then the Aadhaar
  ///         method's where the chain ships it.
  /// @param _deployment The deployment to check.
  /// @param _pins The table entry it was deployed with.
  /// @param _inputs The operator's inputs it was deployed with.
  function _checkDeployment(Deployment memory _deployment, Pins memory _pins, Inputs memory _inputs) internal view {
    address _zkPassportMethod = address(_deployment.zkPassportMethod);
    _checkMethodRoles(_zkPassportMethod, _inputs.zkPassportMethodSafe, _zkPassportKeys(_pins, _inputs));
    _checkMethodInterfaces(_zkPassportMethod);

    if (_pins.shipsAadhaar) {
      address _aadhaarMethod = address(_deployment.aadhaarMethod);
      _checkMethodRoles(_aadhaarMethod, _inputs.aadhaarMethodSafe, _aadhaarKeys(_pins.aadhaarKey));
      _checkMethodInterfaces(_aadhaarMethod);
      _checkAadhaarVerifier(_aadhaarMethod, _pins.aadhaarVerifier);
    }
  }

  /// @notice Requires a method to declare its Safe as key admin and pause holder, no pending holder of either
  ///         role, and exactly the given keys.
  /// @dev The raw answer is compared with the encoding of the expected declaration rather than decoded, so a
  ///      revert, an address with no code and an answer too malformed to decode all fail with the same error.
  /// @param _method The method.
  /// @param _safe The method's Safe.
  /// @param _keys The keys the method was given.
  function _checkMethodRoles(address _method, address _safe, bytes32[] memory _keys) internal view {
    (bool _success, bytes memory _answer) = _method.staticcall(abi.encodeCall(IPolicyMethod.trustedParties, ()));
    bytes memory _expected = abi.encode(_safe, address(0), _keys, _safe, address(0));
    require(_success && keccak256(_answer) == keccak256(_expected), DeployIdentity_MethodRolesMismatch(_method));
  }

  /// @notice Requires a method to answer ERC-165 for the policy-method interface and both role surfaces, the
  ///         questions the setup screen asks before it adopts a method and shows its parties.
  /// @param _method The method.
  function _checkMethodInterfaces(address _method) internal view {
    _requireInterface(_method, type(IPolicyMethod).interfaceId);
    _requireInterface(_method, type(IPolicyMethodPause).interfaceId);
    _requireInterface(_method, type(IPolicyMethodAdmin).interfaceId);
  }

  /// @notice Requires a contract to answer ERC-165 with exactly one ABI-encoded true.
  /// @param _target The contract asked.
  /// @param _interfaceId The interface id asked about.
  function _requireInterface(address _target, bytes4 _interfaceId) internal view {
    (bool _success, bytes memory _answer) =
      _target.staticcall(abi.encodeWithSelector(IPolicyMethod.supportsInterface.selector, _interfaceId));
    require(
      _success && _answer.length == _WORD && abi.decode(_answer, (uint256)) == 1,
      DeployIdentity_InterfaceNotSupported(_target, _interfaceId)
    );
  }

  /// @notice Requires the Aadhaar method to call the pinned verifier, read back from the method. Its constructor
  ///         stores the verifier as given, so this is where a wrong one is caught.
  /// @param _method The Aadhaar method.
  /// @param _expected The pinned verifier.
  function _checkAadhaarVerifier(address _method, address _expected) internal view {
    (bool _read, address _actual) = _readAddress(_method, abi.encodeCall(IAadhaarMethod.verifier, ()));
    require(_read && _actual == _expected, DeployIdentity_AadhaarVerifierMismatch(_expected, _actual));
  }

  /// @notice Requires an address to carry the expected code hash.
  /// @param _component The record key that names the address, for the error.
  /// @param _target The address.
  /// @param _expected The code hash of the kit's code for that address.
  function _requireKitCode(string memory _component, address _target, bytes32 _expected) internal view {
    bytes32 _actual = _target.codehash;
    require(_actual == _expected, DeployIdentity_CodeMismatch(_component, _target, _expected, _actual));
  }

  /// @notice Reads DEPLOYMENT_LABEL from the environment and applies the label rule to it.
  /// @param _chainId The chain id used when no label is set.
  /// @return _label The label.
  function _recordLabel(uint256 _chainId) internal view returns (string memory _label) {
    _label = _labelFor(vm.envExists(_LABEL_VARIABLE), vm.envOr(_LABEL_VARIABLE, string('')), _chainId);
  }

  /// @notice Requires an address a candidate record names to have code on this chain.
  /// @param _target The recorded address.
  /// @return _deployed The same address, once it is known to have code.
  function _requireDeployed(address _target) internal view returns (address _deployed) {
    require(_target.code.length != 0, DeployIdentity_NotDeployed(_target));
    _deployed = _target;
  }

  /// @notice Looks up the table entry for one chain.
  /// @dev Virtual so that a configuration for another chain, such as the local test chain, can supply its own
  ///      entry and keep the deploy logic of this script.
  /// @param _chainId The chain id.
  /// @return _pins The table entry for that chain.
  function _pinsFor(uint256 _chainId) internal pure virtual returns (Pins memory _pins) {
    require(_chainId == _MAINNET_CHAIN_ID || _chainId == _SEPOLIA_CHAIN_ID, DeployIdentity_UnsupportedChain(_chainId));
    _pins.acceptedVersion = _ACCEPTED_VERSION;
    _pins.rootVerifier = _ROOT_VERIFIER;
    _pins.rootRegistry = _ROOT_REGISTRY;
    if (_chainId == _MAINNET_CHAIN_ID) {
      _pins.subVerifier = _MAINNET_SUB_VERIFIER;
      _pins.verifierHelper = _MAINNET_VERIFIER_HELPER;
    } else {
      _pins.subVerifier = _SEPOLIA_SUB_VERIFIER;
      _pins.verifierHelper = _SEPOLIA_VERIFIER_HELPER;
      _pins.shipsAadhaar = true;
      _pins.aadhaarVerifier = _SEPOLIA_AADHAAR_VERIFIER;
      _pins.aadhaarVerifierCodehash = _SEPOLIA_AADHAAR_VERIFIER_CODEHASH;
      _pins.aadhaarKey = _SEPOLIA_AADHAAR_KEY;
    }
  }

  /// @notice Requires the Safe of each method the chain deploys to be nonzero, the zkPassport method's first,
  ///         since a deployment without one must fail rather than leave that method's roles with someone else.
  ///         The error names the variable that holds the zero Safe.
  /// @param _inputs The operator's inputs.
  /// @param _shipsAadhaar Whether the chain deploys the Aadhaar method. Without it, the Aadhaar method's Safe is
  ///        not checked.
  function _checkInputs(Inputs memory _inputs, bool _shipsAadhaar) internal pure {
    require(_inputs.zkPassportMethodSafe != address(0), DeployIdentity_ZeroSafe(_ZKPASSPORT_METHOD_SAFE_VARIABLE));
    if (_shipsAadhaar) {
      require(_inputs.aadhaarMethodSafe != address(0), DeployIdentity_ZeroSafe(_AADHAAR_METHOD_SAFE_VARIABLE));
    }
  }

  /// @notice Builds the eight zkPassport words from the table and the operator's inputs.
  /// @param _pins The table entry.
  /// @param _inputs The operator's inputs.
  /// @return _words The eight words.
  function _zkPassportKeys(Pins memory _pins, Inputs memory _inputs) internal pure returns (bytes32[] memory _words) {
    _words = new bytes32[](_ZKPASSPORT_KEY_COUNT);
    _words[_VERSION_WORD] = _pins.acceptedVersion;
    _words[_ROOT_VERIFIER_WORD] = _toWord(_pins.rootVerifier);
    _words[_SUB_VERIFIER_WORD] = _toWord(_pins.subVerifier);
    _words[_VERIFIER_HELPER_WORD] = _toWord(_pins.verifierHelper);
    _words[_ROOT_REGISTRY_WORD] = _toWord(_pins.rootRegistry);
    _words[_ROOT_ADMIN_WORD] = _toWord(_inputs.rootAdmin);
    _words[_ROOT_GUARDIAN_WORD] = _toWord(_inputs.rootGuardian);
    _words[_SUB_VERIFIER_ADMIN_WORD] = _toWord(_inputs.subVerifierAdmin);
  }

  /// @notice Requires the Aadhaar key not to be the stack's published test key, nor one of UIDAI's two expired
  ///         production keys. UIDAI no longer signs with an expired key, so trusting one would only help someone
  ///         who holds old signed data.
  /// @param _key The key the Aadhaar method would trust.
  function _checkAadhaarKey(bytes32 _key) internal pure {
    require(_key != _AADHAAR_TEST_KEY, DeployIdentity_AadhaarTestKey(_key));
    require(_key != _AADHAAR_UIDAI_2021_KEY && _key != _AADHAAR_UIDAI_2024_KEY, DeployIdentity_AadhaarExpiredKey(_key));
  }

  /// @notice Requires the table values a candidate record holds to equal this chain's table.
  /// @dev A recorded outside address that differs fails as the component check does, and a recorded Aadhaar
  ///      verifier as the verifier check does, each with the table's value as the expected one and the
  ///      candidate's value as the actual one. Any other
  ///      difference, in the accepted version, a role word with stray upper bytes, the Aadhaar verifier's code
  ///      hash or the Aadhaar key, names the record key that holds it.
  /// @param _json The candidate record.
  /// @param _words The recorded zkPassport words.
  /// @param _pins This chain's table entry.
  /// @param _inputs The Safes and role words the record holds.
  function _requireRecordedPins(string memory _json, bytes32[] memory _words, Pins memory _pins, Inputs memory _inputs)
    internal
    pure
  {
    _requireRecordedAddress('rootVerifier', _ROOT_VERIFIER_WORD, _pins.rootVerifier, _words[_ROOT_VERIFIER_WORD]);
    _requireRecordedAddress('subVerifier', _SUB_VERIFIER_WORD, _pins.subVerifier, _words[_SUB_VERIFIER_WORD]);
    _requireRecordedAddress(
      'verifierHelper', _VERIFIER_HELPER_WORD, _pins.verifierHelper, _words[_VERIFIER_HELPER_WORD]
    );
    _requireRecordedAddress('rootRegistry', _ROOT_REGISTRY_WORD, _pins.rootRegistry, _words[_ROOT_REGISTRY_WORD]);
    require(
      keccak256(abi.encode(_words)) == keccak256(abi.encode(_zkPassportKeys(_pins, _inputs))),
      DeployIdentity_RecordMismatch('zkPassportKeys')
    );

    address _recordedVerifier = vm.parseJsonAddress(_json, '.aadhaarVerifier');
    require(
      _recordedVerifier == _pins.aadhaarVerifier,
      DeployIdentity_AadhaarVerifierMismatch(_pins.aadhaarVerifier, _recordedVerifier)
    );
    require(
      vm.parseJsonBytes32(_json, '.aadhaarVerifierCodehash') == _pins.aadhaarVerifierCodehash,
      DeployIdentity_RecordMismatch('aadhaarVerifierCodehash')
    );
    require(vm.parseJsonBytes32(_json, '.aadhaarKey') == _pins.aadhaarKey, DeployIdentity_RecordMismatch('aadhaarKey'));
  }

  /// @notice Requires one recorded outside address to be a clean address word equal to the table's. A word with
  ///         bits above its twenty address bytes fails as not clean, so the mismatch error never shows two equal
  ///         addresses.
  /// @param _component The component's name, for the error.
  /// @param _index The word's position among the zkPassport words, for the error.
  /// @param _pinned The table's address.
  /// @param _recorded The recorded word.
  function _requireRecordedAddress(string memory _component, uint256 _index, address _pinned, bytes32 _recorded)
    internal
    pure
  {
    _requireCleanWord(_index, _recorded);
    address _recordedAddress = _toAddress(_recorded);
    require(_recorded == _toWord(_pinned), DeployIdentity_ComponentMismatch(_component, _pinned, _recordedAddress));
  }

  /// @notice The label rule: the decimal chain id without a set value, else the value once it passes the
  ///         character and length checks.
  /// @param _isSet Whether a label value was given.
  /// @param _value The label value, read only when _isSet is true.
  /// @param _chainId The chain id used when no value is set.
  /// @return _label The label.
  function _labelFor(bool _isSet, string memory _value, uint256 _chainId) internal pure returns (string memory _label) {
    if (_isSet) {
      _requireValidLabel(_value);
      _label = _value;
    } else {
      _label = vm.toString(_chainId);
    }
  }

  /// @notice Requires a label to be 1 to 64 characters of lowercase letters, digits and the hyphen, with at least
  ///         one character that is not a digit. A slash or a dot could lead the record outside script/deployments,
  ///         and a label of digits alone could take another chain's default record name, such as 1.identity.json
  ///         written from Sepolia.
  /// @param _label The label.
  function _requireValidLabel(string memory _label) internal pure {
    bytes memory _characters = bytes(_label);
    bool _valid = _characters.length != 0 && _characters.length < _MAX_LABEL_LENGTH + 1;
    bool _hasNonDigit;
    for (uint256 _i; _valid && _i < _characters.length; ++_i) {
      _valid = _isLabelCharacter(_characters[_i]);
      _hasNonDigit = _hasNonDigit || !_isDigit(_characters[_i]);
    }
    require(_valid && _hasNonDigit, DeployIdentity_InvalidLabel(_label));
  }

  /// @notice Tells whether a character may appear in a label.
  /// @dev The bounds sit one past the range: 0x60 and 0x7b around a to z.
  /// @param _character The character.
  /// @return _allowed True for a lowercase letter, a digit or the hyphen.
  function _isLabelCharacter(bytes1 _character) internal pure returns (bool _allowed) {
    bool _isLetter = _character > 0x60 && _character < 0x7b;
    _allowed = _isLetter || _isDigit(_character) || _character == '-';
  }

  /// @notice Tells whether a character is a decimal digit.
  /// @dev The bounds sit one past the range: 0x2f and 0x3a around 0 to 9.
  /// @param _character The character.
  /// @return _digit True for 0 to 9.
  function _isDigit(bytes1 _character) internal pure returns (bool _digit) {
    _digit = _character > 0x2f && _character < 0x3a;
  }

  /// @notice Requires an address word to have no bit set above its twenty address bytes.
  /// @param _index The word's position among the zkPassport words, for the error.
  /// @param _word The word.
  function _requireCleanWord(uint256 _index, bytes32 _word) internal pure {
    require(uint256(_word) >> 160 == 0, DeployIdentity_WordNotClean(_index, _word));
  }

  /// @notice Wraps the Aadhaar key in the one-word list the Aadhaar method takes.
  /// @param _key The key.
  /// @return _keys The list.
  function _aadhaarKeys(bytes32 _key) internal pure returns (bytes32[] memory _keys) {
    _keys = new bytes32[](1);
    _keys[0] = _key;
  }

  /// @notice Left-pads an address to one word.
  /// @param _account The address.
  /// @return _word The word.
  function _toWord(address _account) internal pure returns (bytes32 _word) {
    _word = bytes32(uint256(uint160(_account)));
  }

  /// @notice Reads the low twenty bytes of a word as an address, for error values and calls. Every comparison is
  ///         made on whole words, so a truncated word never passes one.
  /// @param _word The word.
  /// @return _account The address.
  function _toAddress(bytes32 _word) internal pure returns (address _account) {
    _account = address(uint160(uint256(_word)));
  }
}
