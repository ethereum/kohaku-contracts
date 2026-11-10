// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import {IZkPassportRootVerifier} from 'contracts/methods/zkpassport/IZkPassportRootVerifier.sol';
import {IZkPassportVerifierHelper} from 'contracts/methods/zkpassport/IZkPassportVerifierHelper.sol';

/// @notice The role addresses the local zkPassport stand-ins answer, which the local identity deployment passes as the
///         operator's reviewed inputs.
library LocalIdentityRoles {
  /// @notice The admin the local root verifier and sub-verifier answer.
  address internal constant ROOT_ADMIN = address(uint160(uint256(keccak256('local zkPassport root admin'))));
  /// @notice The root guardian the local root verifier answers.
  address internal constant ROOT_GUARDIAN = address(uint160(uint256(keccak256('local zkPassport root guardian'))));
}

/// @notice A stand-in for zkPassport's root verifier: it routes each accepted version to a sub-verifier and a verifier
///         helper, and answers a proof with the identifier the passport derives under that version.
/// @dev What it replaces: zkPassport's root verifier at 0x1D000001000EFD9a6371f4d90bB8920D5431c0D8 and the
///      UltraHonk sub-verifier behind it. Why the real one is not used: it exists only on mainnet and Sepolia, and a
///      real proof needs a real passport. Here a proof's `proof` bytes carry the passport's secret, and the
///      identifier is keccak256(derivation, secret), where the derivation is fixed per version, so a release that
///      changes it changes every identifier. Which tests cover the real one:
///      test/method-zkpassport/fork/ZkPassportMethodFork.t.sol and
///      test/deploy-identity/fork/DeployIdentityZkPassportVerdictFork.t.sol verify a real proof against the
///      deployed verifier.
contract LocalZkPassportRootVerifier {
  /// @notice The sub-verifier each version routes to.
  mapping(bytes32 _version => address _subVerifier) public getSubVerifier;
  /// @notice The verifier helper each version routes to.
  mapping(bytes32 _version => address _helper) public getHelper;
  /// @notice The identifier derivation each version uses.
  mapping(bytes32 _version => bytes32 _derivation) public derivationOf;
  /// @notice The root registry the verifier names, under the upstream getter's name.
  // solhint-disable-next-line immutable-vars-naming
  address public immutable rootRegistry;

  /// @notice Only the upstream admin may route a version.
  error LocalZkPassportRootVerifier_NotAdmin();

  constructor(bytes32 _version, address _subVerifier, address _helper, address _registry, bytes32 _derivation) {
    getSubVerifier[_version] = _subVerifier;
    getHelper[_version] = _helper;
    derivationOf[_version] = _derivation;
    rootRegistry = _registry;
  }

  /// @notice The upstream admin.
  function admin() external pure returns (address _admin) {
    _admin = LocalIdentityRoles.ROOT_ADMIN;
  }

  /// @notice The upstream root guardian.
  function guardian() external pure returns (address _guardian) {
    _guardian = LocalIdentityRoles.ROOT_GUARDIAN;
  }

  /// @notice zkPassport ships a release: a version routed to a sub-verifier and verifier helper, with its derivation.
  function addVersion(bytes32 _version, address _subVerifier, address _helper, bytes32 _derivation) external {
    require(msg.sender == LocalIdentityRoles.ROOT_ADMIN, LocalZkPassportRootVerifier_NotAdmin());
    getSubVerifier[_version] = _subVerifier;
    getHelper[_version] = _helper;
    derivationOf[_version] = _derivation;
  }

  /// @notice Verifies a proof under the version the method asks for. A version nobody routed fails.
  function verify(IZkPassportRootVerifier.ProofVerificationParams calldata _params)
    external
    view
    returns (bool _valid, bytes32 _uniqueIdentifier, IZkPassportVerifierHelper _helper)
  {
    _helper = IZkPassportVerifierHelper(getHelper[_params.version]);
    if (address(_helper) == address(0)) return (false, bytes32(0), _helper);
    bytes32 _passportSecret = abi.decode(_params.proofVerificationData.proof, (bytes32));
    _uniqueIdentifier = keccak256(abi.encode(derivationOf[_params.version], _passportSecret));
    _valid = true;
  }
}

/// @notice A stand-in for zkPassport's verifier helper: the committed inputs carry the custom data as one string.
/// @dev Replaces the deployed verifier helper for the reason and with the coverage LocalZkPassportRootVerifier names.
contract LocalZkPassportHelper {
  /// @notice Reads the bound data out of the committed inputs.
  function getBoundData(bytes calldata _committedInputs)
    external
    view
    returns (IZkPassportVerifierHelper.BoundData memory _boundData)
  {
    _boundData.chainId = block.chainid;
    _boundData.customData = abi.decode(_committedInputs, (string));
  }
}

/// @notice A stand-in for zkPassport's sub-verifier, of which the deployment reads only the admin.
/// @dev Replaces the deployed sub-verifier for the reason and with the coverage LocalZkPassportRootVerifier names.
contract LocalZkPassportSubVerifier {
  /// @notice The upstream admin.
  function admin() external pure returns (address _admin) {
    _admin = LocalIdentityRoles.ROOT_ADMIN;
  }
}

/// @notice A stand-in for zkPassport's root registry, which the deployment only requires to have code.
/// @dev Replaces the deployed registry for the reason and with the coverage LocalZkPassportRootVerifier names.
contract LocalZkPassportRegistry {
  /// @notice Marks the registry as live.
  function live() external pure returns (bool _live) {
    _live = true;
  }
}

/// @notice A stand-in for Anon Aadhaar's raw Groth16 verifier that accepts every proof.
/// @dev What it replaces: the Groth16 verifier at 0xCBd85cd69C4779aA9a7AB9B6D6A9f6FEd61504F0 on Sepolia. Why the
///      real one is not used: a real proof needs a QR code signed by an issuer key, which no story can produce for
///      invented people. With it the Aadhaar method's own checks still run: the issuer key hash, the nullifier, the
///      seed, the digest and the QR's age. Which test covers the real one:
///      test/method-aadhaar/AadhaarMethodFork.t.sol verifies a real proof against the live Sepolia verifier.
contract LocalAadhaarGroth16Verifier {
  /// @notice Accepts any proof.
  function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[9] calldata)
    external
    pure
    returns (bool _valid)
  {
    _valid = true;
  }
}

/// @notice A stand-in for a Safe smart wallet guardian: owners, a threshold, ERC-1271 over Safe's own message hash, and
///         owner-signed transactions to manage its owners.
/// @dev What it replaces: a Safe with its CompatibilityFallbackHandler. Why the real one is not used: the local
///      chain has no Safe singleton, and the stories need only who may sign for the wallet. Its ERC-1271 answer
///      follows Safe's: the owners sign keccak256(0x1901, domain, keccak256(SafeMessage(keccak256(abi.encode(hash)))))
///      and the signatures sit sorted by owner. Which test covers a smart-wallet guardian on the method's side:
///      test/method-ecdsa/EcdsaMethodVerifyContract.t.sol covers the ERC-1271 path; no test runs a real Safe.
contract LocalSafe {
  /// @notice Safe's domain type hash.
  bytes32 internal constant _DOMAIN_SEPARATOR_TYPEHASH =
    keccak256('EIP712Domain(uint256 chainId,address verifyingContract)');
  /// @notice Safe's message type hash.
  bytes32 internal constant _SAFE_MSG_TYPEHASH = keccak256('SafeMessage(bytes message)');

  /// @notice Whether an address is an owner.
  mapping(address _owner => bool _isOwner) public isOwner;
  /// @notice How many owner signatures a message or a transaction needs.
  uint256 public threshold;
  /// @notice The transaction nonce.
  uint256 public nonce;

  /// @notice The owner signatures are missing, out of order or not from owners.
  error LocalSafe_InvalidSignatures();
  /// @notice An owner-signed transaction failed.
  error LocalSafe_TransactionFailed();
  /// @notice Only the Safe itself may manage its owners.
  error LocalSafe_OnlySelf();

  constructor(address[] memory _owners, uint256 _threshold) {
    for (uint256 _i; _i < _owners.length; ++_i) {
      isOwner[_owners[_i]] = true;
    }
    threshold = _threshold;
  }

  /// @notice Replaces one owner with another. Only the Safe itself, through an owner-signed transaction.
  function swapOwner(address _oldOwner, address _newOwner) external {
    require(msg.sender == address(this), LocalSafe_OnlySelf());
    isOwner[_oldOwner] = false;
    isOwner[_newOwner] = true;
  }

  /// @notice Runs one call the owners signed.
  function execTransaction(address _to, bytes calldata _data, bytes calldata _signatures) external {
    bytes32 _txHash = transactionHash(_to, _data, nonce);
    nonce++;
    require(_checkSignatures(_txHash, _signatures), LocalSafe_InvalidSignatures());
    (bool _ok,) = _to.call(_data);
    require(_ok, LocalSafe_TransactionFailed());
  }

  /// @notice ERC-1271 as Safe's fallback handler answers it.
  function isValidSignature(bytes32 _hash, bytes calldata _signatures) external view returns (bytes4 _magicValue) {
    if (_checkSignatures(messageHash(_hash), _signatures)) _magicValue = 0x1626ba7e;
  }

  /// @notice The hash the owners sign for an ERC-1271 message.
  function messageHash(bytes32 _hash) public view returns (bytes32 _messageHash) {
    bytes32 _domain = keccak256(abi.encode(_DOMAIN_SEPARATOR_TYPEHASH, block.chainid, address(this)));
    bytes32 _safeMessage = keccak256(abi.encode(_SAFE_MSG_TYPEHASH, keccak256(abi.encode(_hash))));
    _messageHash = keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), _domain, _safeMessage));
  }

  /// @notice The hash the owners sign for a transaction.
  function transactionHash(address _to, bytes calldata _data, uint256 _nonce) public view returns (bytes32 _txHash) {
    _txHash = keccak256(abi.encode(address(this), block.chainid, _to, keccak256(_data), _nonce));
  }

  /// @notice Requires `threshold` signatures from distinct owners, sorted by owner address.
  function _checkSignatures(bytes32 _hash, bytes calldata _signatures) internal view returns (bool _valid) {
    if (_signatures.length < threshold * 65) return false;
    address _last;
    for (uint256 _i; _i < threshold; ++_i) {
      (address _owner, ECDSA.RecoverError _error,) = ECDSA.tryRecover(_hash, _signatures[_i * 65:(_i + 1) * 65]);
      if (_error != ECDSA.RecoverError.NoError || !isOwner[_owner] || !(_owner > _last)) return false;
      _last = _owner;
    }
    _valid = true;
  }
}

/// @notice A stand-in for USDC: an ERC-20 with six decimals that anyone can mint on the local chain.
/// @dev What it replaces: Circle's USDC. Why the real one is not used: the stories need a token that moves
///      balances on transfer, nothing USDC-specific, and the local chain has no USDC. The payment call the action
///      builds is a plain transfer, which test/action/fork/AmbireRecoveryActionSpendFork.t.sol runs on a fork.
contract LocalUsdc is ERC20 {
  constructor() ERC20('USD Coin', 'USDC') {}

  /// @notice Credits an amount, the way funding an account from an exchange would.
  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }

  /// @inheritdoc ERC20
  function decimals() public pure override returns (uint8 _decimals) {
    _decimals = 6;
  }
}

/// @notice A token whose transfer answers false and moves nothing, a nonstandard token some issuers ship.
/// @dev It stands for the class of tokens the action's payment call does not check. No real token is used because
///      the shape is the point. test/action/AmbireRecoveryActionExecuteHandover.t.sol covers it at the unit level.
contract FalseReturningToken {
  /// @notice Balances.
  mapping(address _holder => uint256 _balance) public balanceOf;

  /// @notice Credits an amount.
  function mint(address _to, uint256 _amount) external {
    balanceOf[_to] += _amount;
  }

  /// @notice Moves nothing and answers false.
  function transfer(address, uint256) external pure returns (bool _ok) {
    _ok = false;
  }
}

/// @notice A payee contract that refuses the native asset, such as a sponsor's contract wallet with no receive.
/// @dev It stands for any payee whose receipt reverts. No real contract is used because the refusal is the point.
contract RefusingPayee {
  /// @notice The refusal.
  error RefusingPayee_Refused();

  /// @notice Refuses every payment.
  receive() external payable {
    revert RefusingPayee_Refused();
  }
}
