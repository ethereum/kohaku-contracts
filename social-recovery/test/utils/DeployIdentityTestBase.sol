// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';
import {DeployIdentity} from 'script/DeployIdentity.s.sol';
import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {AadhaarMethod} from 'contracts/methods/aadhaar/AadhaarMethod.sol';
import {ZkPassportMethod} from 'contracts/methods/zkpassport/ZkPassportMethod.sol';
import {
  DeployIdentityMockLiveReads,
  DeployIdentityMockRootVerifier,
  DeployIdentityMockSubVerifier
} from 'test/mocks/DeployIdentityMockLiveReads.sol';

/// @notice Shared setup for the identity deployment script's tests. It creates the script, a local table whose
///         addresses hold code, operator inputs hashed from labels, and a good deployment of the kit's real
///         zkPassport and Aadhaar methods built by hand with those values, which the checks accept and each
///         crafted bad value departs from in one place.
abstract contract DeployIdentityTestBase is Test {
  /// @notice Mainnet's chain id.
  uint256 internal constant _MAINNET_CHAIN_ID = 1;
  /// @notice Sepolia's chain id.
  uint256 internal constant _SEPOLIA_CHAIN_ID = 11_155_111;

  /// @notice zkPassport 0.21.1 as a version word: major, minor and patch as three big-endian uint16 values,
  ///         then zeroes. It is the version both chains accept.
  bytes32 internal constant _VERSION_0_21_1 = 0x0000001500010000000000000000000000000000000000000000000000000000;

  /// @notice zkPassport's root verifier, the same address on mainnet and Sepolia.
  address internal constant _ROOT_VERIFIER = 0x1D000001000EFD9a6371f4d90bB8920D5431c0D8;
  /// @notice zkPassport's root registry, the same address on mainnet and Sepolia.
  address internal constant _ROOT_REGISTRY = 0x1D0000020038d6E40E1d98e09fA1bb3A7DAA8B70;
  /// @notice The version 0.21.1 sub-verifier on mainnet.
  address internal constant _MAINNET_SUB_VERIFIER = 0xBeAE01953C520A49eE869c02edBE69D6da93D965;
  /// @notice The verifier helper the mainnet route uses for version 0.21.1.
  address internal constant _MAINNET_VERIFIER_HELPER = 0x1E878E61D565F4c40FC40235D4c4A5FC66Afab2D;
  /// @notice The version 0.21.1 sub-verifier on Sepolia.
  address internal constant _SEPOLIA_SUB_VERIFIER = 0x77cB76Df1b37644126f8e04caA88356F78A61e47;
  /// @notice The verifier helper the Sepolia route uses for version 0.21.1.
  address internal constant _SEPOLIA_VERIFIER_HELPER = 0xe8AE97eF2fFF59597D1B6882286754FEC200F3a9;

  /// @notice The Anon Aadhaar Groth16 verifier on Sepolia.
  address internal constant _SEPOLIA_AADHAAR_VERIFIER = 0xCBd85cd69C4779aA9a7AB9B6D6A9f6FEd61504F0;
  /// @notice The hash of UIDAI's current public key, the Aadhaar method's one trusted key on Sepolia.
  bytes32 internal constant _UIDAI_KEY = bytes32(
    uint256(19_770_349_258_225_098_911_243_612_275_321_727_303_641_256_718_510_179_842_211_794_623_059_325_011_884)
  );
  /// @notice The code hash of the Sepolia Groth16 verifier, the code the Aadhaar method was reviewed against.
  bytes32 internal constant _SEPOLIA_AADHAAR_VERIFIER_CODEHASH =
    0x7e2982555ebd6cae0492f083ab5bc6d2753249ed2a8b9d1391f643beba23db47;
  /// @notice The public-key hash of the Anon Aadhaar stack's published test key, at the pinned anon-aadhaar
  ///         revision. Anyone holding the published test private key can sign any identity under it. It is the
  ///         key input of the real proof in test/fixtures/aadhaar, which the live Sepolia verifier accepts.
  bytes32 internal constant _AADHAAR_TEST_KEY = bytes32(
    uint256(15_134_874_015_316_324_267_425_466_444_584_014_077_184_337_590_635_665_158_241_104_437_045_239_495_873)
  );

  /// @notice The public-key hash of UIDAI's 2021 production certificate, expired. Anon Aadhaar's
  ///         productionPublicKeyHash, 18063425702624337643644061197836918910810808173893535653269228433734128853484.
  bytes32 internal constant _AADHAAR_EXPIRED_2021_KEY =
    0x27ef89612fc4a823b52a334ed4f2a48f8d066d8b3ed2ba5672bb5f531aab61ec;
  /// @notice The public-key hash of UIDAI's 2024 production certificate, expired, decimal
  ///         7217153585153042436745665065617781483037900263075488870028184365042423808319.
  bytes32 internal constant _AADHAAR_EXPIRED_2024_KEY =
    0x0ff4c3a0af5fb98ae76bfedb5fd93598e030a07302ad42f6a8719f93015bc13f;

  /// @notice The size of the eight-word zkPassport trusted-key list.
  uint256 internal constant _KEY_COUNT = 8;

  /// @notice The selectors of the six live reads the zkPassport comparison makes.
  bytes4 internal constant _GET_SUB_VERIFIER = bytes4(keccak256('getSubVerifier(bytes32)'));
  bytes4 internal constant _GET_HELPER = bytes4(keccak256('getHelper(bytes32)'));
  bytes4 internal constant _ROOT_REGISTRY_READ = bytes4(keccak256('rootRegistry()'));
  bytes4 internal constant _ADMIN = bytes4(keccak256('admin()'));
  bytes4 internal constant _GUARDIAN = bytes4(keccak256('guardian()'));

  DeployIdentity internal _script;
  /// @notice A mock root verifier and sub-verifier, set by `_useLiveReadMocks`.
  DeployIdentityMockRootVerifier internal _rootMock;
  DeployIdentityMockSubVerifier internal _subMock;
  /// @notice A local table: every address holds code, the version is 0.21.1, and the Aadhaar method ships with
  ///         UIDAI's key and the code hash of the code etched at its verifier.
  IDeployIdentity.Pins internal _pins;
  /// @notice Operator inputs hashed from labels. The two methods' Safes are different addresses, so a role given
  ///         to the other method's Safe shows up as a mismatch.
  IDeployIdentity.Inputs internal _inputs;
  /// @notice A good deployment: the kit's real methods, built with `_pins` and `_inputs`, both roles of each method
  ///         on that method's own Safe.
  IDeployIdentity.Deployment internal _good;

  function setUp() public virtual {
    _script = new DeployIdentity();
    _pins = IDeployIdentity.Pins({
      acceptedVersion: _VERSION_0_21_1,
      rootVerifier: _codeAt('localRootVerifier'),
      subVerifier: _codeAt('localSubVerifier'),
      verifierHelper: _codeAt('localVerifierHelper'),
      rootRegistry: _codeAt('localRootRegistry'),
      shipsAadhaar: true,
      aadhaarVerifier: _codeAt('localAadhaarVerifier'),
      aadhaarVerifierCodehash: bytes32(0),
      aadhaarKey: _UIDAI_KEY
    });
    _pins.aadhaarVerifierCodehash = _pins.aadhaarVerifier.codehash;
    _inputs = IDeployIdentity.Inputs({
      zkPassportMethodSafe: _freshAddress('zkPassportMethodSafe', 0),
      aadhaarMethodSafe: _freshAddress('aadhaarMethodSafe', 0),
      rootAdmin: _freshAddress('rootAdmin', 0),
      rootGuardian: _freshAddress('rootGuardian', 0),
      subVerifierAdmin: _freshAddress('subVerifierAdmin', 0)
    });
    _good = IDeployIdentity.Deployment({
      zkPassportMethod: _newZkPassportMethod(
        _inputs.zkPassportMethodSafe, _inputs.zkPassportMethodSafe, _words(_pins, _inputs)
      ),
      aadhaarMethod: _newAadhaarMethod(
        _inputs.aadhaarMethodSafe, _inputs.aadhaarMethodSafe, _pins.aadhaarKey, _pins.aadhaarVerifier
      )
    });
  }

  /*///////////////////////////////////////////////////////////////
                            BUILDERS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The eight zkPassport trusted-key words for a table and operator inputs, in the method's order: the
  ///         accepted version, the root verifier, the sub-verifier, the verifier helper, the root registry, the root
  ///         admin, the root guardian and the sub-verifier admin. Each address is left-padded to one word.
  function _words(IDeployIdentity.Pins memory _table, IDeployIdentity.Inputs memory _operator)
    internal
    pure
    returns (bytes32[] memory _keys)
  {
    _keys = new bytes32[](_KEY_COUNT);
    _keys[0] = _table.acceptedVersion;
    _keys[1] = _word(_table.rootVerifier);
    _keys[2] = _word(_table.subVerifier);
    _keys[3] = _word(_table.verifierHelper);
    _keys[4] = _word(_table.rootRegistry);
    _keys[5] = _word(_operator.rootAdmin);
    _keys[6] = _word(_operator.rootGuardian);
    _keys[7] = _word(_operator.subVerifierAdmin);
  }

  /// @notice An address left-padded to one word.
  function _word(address _account) internal pure returns (bytes32 _value) {
    _value = bytes32(uint256(uint160(_account)));
  }

  /// @notice A one-word list holding `_key`, the Aadhaar method's trusted keys.
  function _oneKey(bytes32 _key) internal pure returns (bytes32[] memory _keys) {
    _keys = new bytes32[](1);
    _keys[0] = _key;
  }

  /// @notice Deploys the kit's zkPassport method with the given pause holder, key admin and words.
  function _newZkPassportMethod(address _pauseHolder, address _admin, bytes32[] memory _keys)
    internal
    returns (IPolicyMethod _method)
  {
    _method = IPolicyMethod(address(new ZkPassportMethod(_pauseHolder, _admin, _keys)));
  }

  /// @notice Deploys the kit's Aadhaar method with the given pause holder, key admin, key and verifier.
  function _newAadhaarMethod(address _pauseHolder, address _admin, bytes32 _key, address _verifier)
    internal
    returns (IPolicyMethod _method)
  {
    _method = IPolicyMethod(address(new AadhaarMethod(_pauseHolder, _admin, _oneKey(_key), _verifier)));
  }

  /// @notice Hashes a number and a label into an address no fixture uses. The fuzzer seeds its inputs with
  ///         addresses it reads from state, so a number mapped straight onto an address can land on a fixture
  ///         address.
  function _freshAddress(string memory _label, uint256 _seed) internal pure returns (address _fresh) {
    _fresh = address(uint160(uint256(keccak256(abi.encode(_label, _seed)))));
  }

  /// @notice A fresh address, hashed from `_label`, that holds one byte of code.
  function _codeAt(string memory _label) internal returns (address _account) {
    _account = _freshAddress(_label, 0);
    vm.etch(_account, hex'00');
  }

  /// @notice Puts a mock root verifier and a mock sub-verifier in `_pins` and makes every live read agree with
  ///         `_pins` and `_inputs`: the root routes 0.21.1 to the mock sub-verifier with `_pins.verifierHelper`, names
  ///         `_pins.rootRegistry`, and reports `_inputs`' root admin and root guardian, and the sub-verifier reports
  ///         `_inputs`' sub-verifier admin.
  function _useLiveReadMocks() internal {
    _rootMock = new DeployIdentityMockRootVerifier();
    _subMock = new DeployIdentityMockSubVerifier();
    _rootMock.setVersion(_pins.acceptedVersion);
    _pins.rootVerifier = address(_rootMock);
    _pins.subVerifier = address(_subMock);
    DeployIdentityMockLiveReads.Mode _value = DeployIdentityMockLiveReads.Mode.Value;
    _rootMock.setAnswer(_GET_SUB_VERIFIER, _value, address(_subMock));
    _rootMock.setAnswer(_GET_HELPER, _value, _pins.verifierHelper);
    _rootMock.setAnswer(_ROOT_REGISTRY_READ, _value, _pins.rootRegistry);
    _rootMock.setAnswer(_ADMIN, _value, _inputs.rootAdmin);
    _rootMock.setAnswer(_GUARDIAN, _value, _inputs.rootGuardian);
    _subMock.setAnswer(_ADMIN, _value, _inputs.subVerifierAdmin);
  }

  /*///////////////////////////////////////////////////////////////
                        RECORDED ACCESSES
  ///////////////////////////////////////////////////////////////*/

  /// @notice Counts the contract creations among recorded account accesses, reverted ones included, so a
  ///         creation that a later revert undid still counts.
  function _creations(VmSafe.AccountAccess[] memory _accesses) internal pure returns (uint256 _count) {
    for (uint256 _i; _i < _accesses.length; ++_i) {
      if (_accesses[_i].kind == VmSafe.AccountAccessKind.Create) ++_count;
    }
  }

  /// @notice Counts the contract creations among recorded account accesses that the broadcaster made, the ones a
  ///         broadcast would send. Under forge test a script that starts a broadcast with no key sends as forge's
  ///         default sender, so a creation the script makes itself outside the broadcast, such as a local copy it
  ///         builds only to read a code hash, is never sent and is not counted.
  function _broadcastCreations(VmSafe.AccountAccess[] memory _accesses) internal pure returns (uint256 _count) {
    for (uint256 _i; _i < _accesses.length; ++_i) {
      if (_accesses[_i].kind == VmSafe.AccountAccessKind.Create && _accesses[_i].accessor == DEFAULT_SENDER) {
        ++_count;
      }
    }
  }

  /// @notice Whether the recorded accesses hold a call, reverted or not, to `_target` with exactly `_data` as
  ///         calldata.
  function _called(VmSafe.AccountAccess[] memory _accesses, address _target, bytes memory _data)
    internal
    pure
    returns (bool _found)
  {
    for (uint256 _i; _i < _accesses.length && !_found; ++_i) {
      VmSafe.AccountAccessKind _kind = _accesses[_i].kind;
      _found = (_kind == VmSafe.AccountAccessKind.Call || _kind == VmSafe.AccountAccessKind.StaticCall)
        && _accesses[_i].account == _target && keccak256(_accesses[_i].data) == keccak256(_data);
    }
  }

  /// @notice Calls deploy while recording account accesses and returns the revert data and how many contracts
  ///         deploy created before it reverted. Fails the test when deploy does not revert.
  function _deployReverting(IDeployIdentity.Pins memory _table, IDeployIdentity.Inputs memory _operator)
    internal
    returns (bytes memory _reason, uint256 _created)
  {
    vm.startStateDiffRecording();
    try _script.deploy(_table, _operator) {
      fail('deploy did not revert');
    } catch (bytes memory _caught) {
      _reason = _caught;
    }
    _created = _creations(vm.stopAndReturnStateDiff());
  }

  /*///////////////////////////////////////////////////////////////
                        NAMED MISMATCHES
  ///////////////////////////////////////////////////////////////*/

  /// @notice Asserts that `_reason` is exactly the error `_selector` carrying `_name`, `_expected` and `_actual`.
  function _assertNamedMismatch(
    bytes memory _reason,
    bytes4 _selector,
    string memory _name,
    address _expected,
    address _actual
  ) internal pure {
    assertEq(_reason, abi.encodeWithSelector(_selector, _name, _expected, _actual), 'revert data');
  }

  /// @notice Asserts that `_reason` is the error `_selector` carrying `_name` and `_expected`, whatever live value
  ///         it reports. A read that reverted, answered nothing or answered a malformed word has no address to
  ///         report, so only the name and the expected word are fixed.
  function _assertNamedMismatchAnyActual(bytes memory _reason, bytes4 _selector, string memory _name, address _expected)
    internal
    pure
  {
    (bytes4 _found, string memory _decodedName, address _decodedExpected,) = _decodeMismatch(_reason);
    assertEq(_found, _selector, 'error selector');
    assertEq(_decodedName, _name, 'name');
    assertEq(_decodedExpected, _expected, 'expected value');
  }

  /// @notice Splits a mismatch error into its selector, its name, its expected and its actual address.
  function _decodeMismatch(bytes memory _reason)
    internal
    pure
    returns (bytes4 _selector, string memory _name, address _expected, address _actual)
  {
    assertGt(_reason.length, 4, 'revert data too short');
    assembly {
      _selector := mload(add(_reason, 32))
    }
    bytes memory _arguments = new bytes(_reason.length - 4);
    for (uint256 _i; _i < _arguments.length; ++_i) {
      _arguments[_i] = _reason[_i + 4];
    }
    (_name, _expected, _actual) = abi.decode(_arguments, (string, address, address));
  }
}
