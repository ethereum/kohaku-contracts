// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {Base64} from '@openzeppelin/contracts/utils/Base64.sol';

import {BindingDigest} from 'libraries/BindingDigest.sol';
import {SetupBody} from 'libraries/SetupBody.sol';
import {IPolicyManager} from 'interfaces/IPolicyManager.sol';
import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';
import {IRecoveryAction} from 'interfaces/IRecoveryAction.sol';

import {IDeployIdentity} from 'script/IDeployIdentity.sol';
import {IAmbireAccount} from 'contracts/actions/ambire/IAmbireAccount.sol';
import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';
import {AadhaarMethod} from 'contracts/methods/aadhaar/AadhaarMethod.sol';
import {IZkPassportRootVerifier} from 'contracts/methods/zkpassport/IZkPassportRootVerifier.sol';
import {ZkPassportMethod} from 'contracts/methods/zkpassport/ZkPassportMethod.sol';

import {LocalAmbireAccount, LocalAmbireFactory, LocalEntryPoint} from 'test/integration/base/LocalAmbire.sol';
import {LocalChain, LocalDeploy, LocalDeployIdentity} from 'test/integration/base/LocalDeploy.sol';
import {LocalIdentityRoles, LocalSafe, LocalUsdc} from 'test/integration/base/LocalWorld.sol';
import {ActionAmbireProxy} from 'test/utils/ActionAmbireProxy.sol';

/// @notice The world every integration story runs in. The kit is deployed by the real deployment scripts, through their
///         local chain configuration, and the people of the stories hold real keys: wallets sign with secp256k1,
///         passkeys with P-256, and identity proofs carry what the identity methods check.
/// @dev The functions here hide mechanics, the signatures, payloads and encodings. Each step of a story stays in the
///      test that tells it.
// The base holds the whole world of the stories, so it keeps more state than a contract normally would.
// solhint-disable-next-line max-states-count
abstract contract IntegrationBase is Test, LocalDeploy {
  /*///////////////////////////////////////////////////////////////
                              TYPES
  ///////////////////////////////////////////////////////////////*/

  /// @notice The prefix of every story person's label. A key derived from a bare name such as 'attacker' is public, and
  ///         on mainnet that address already carries an EIP-7702 delegation, so the wallet method would read it as a
  ///         smart wallet on a fork.
  string internal constant _PEOPLE_PREFIX = 'social recovery story: ';

  /// @notice Where a story runs.
  enum ForkChain {
    Local,
    Mainnet,
    Sepolia
  }

  /// @notice One credential of a rule, as the holder's configuration writes it out.

  struct Credential {
    address method;
    bytes config;
    bytes32 salt;
  }

  /// @notice A rule as the holder's configuration holds it: the wait, the pause choice, and the clauses, each a
  ///         threshold over a run of consecutive places.
  struct Rule {
    uint48 wait;
    bool ignoresPause;
    uint8[] thresholds;
    uint256[] clauseSizes;
    Credential[] places;
  }

  /// @notice Who stands behind a credential and how they prove.
  enum SignerKind {
    None,
    WalletKey,
    SafeOwners,
    Passkey,
    Aadhaar,
    Passport
  }

  /// @notice What a person behind a credential holds.
  struct Signer {
    SignerKind kind;
    uint256 key;
    uint256[] safeOwnerKeys;
    uint256 aadhaarNullifier;
    uint256 aadhaarSeed;
    bytes32 qrIssuerKey;
    uint256 qrSignedAt;
    bytes32 passportSecret;
  }

  /// @notice One person with a wallet key.
  struct Person {
    address addr;
    uint256 key;
  }

  /*///////////////////////////////////////////////////////////////
                            CONSTANTS
  ///////////////////////////////////////////////////////////////*/

  /// @notice A morning in October 2025, when the stories start.
  uint256 internal constant _STORY_START = 1_760_000_000;
  /// @notice The domain Maya's wallet created her passkeys for.
  string internal constant _PASSKEY_DOMAIN = 'wallet.example';
  /// @notice The privilege Ambire's extension writes for an account's own key.
  bytes32 internal constant _SIGNER_PRIVILEGE = bytes32(uint256(2));
  /// @notice Ambire's account factory on mainnet and Sepolia.
  address internal constant _AMBIRE_FACTORY = 0x26cE6745A633030A6faC5e64e41D21fb6246dc2d;
  /// @notice What a new account holds in ETH when it is opened.
  uint256 internal constant _OPENING_BALANCE = 1 ether;
  /// @notice The zkPassport domain and scope the holder's wallet asks a passport proof for.
  string internal constant _PASSPORT_DOMAIN = 'wallet.example';
  string internal constant _PASSPORT_SCOPE = 'recovery';

  /*///////////////////////////////////////////////////////////////
                              ERRORS
  ///////////////////////////////////////////////////////////////*/

  /// @notice A story asked for a proof of a credential nobody in it holds.
  error IntegrationBase_NobodyStandsBehindTheCredential();
  /// @notice INTEGRATION_FORK names a chain the stories do not fork.
  error IntegrationBase_UnknownFork(string _fork);

  /*///////////////////////////////////////////////////////////////
                         DEPLOYED CONTRACTS
  ///////////////////////////////////////////////////////////////*/

  IPolicyManager internal _manager;
  IPolicyMethod internal _ecdsaMethod;
  IPolicyMethod internal _passkeyMethod;
  IAmbireRecoveryAction internal _action;
  AadhaarMethod internal _aadhaarMethod;
  ZkPassportMethod internal _zkPassportMethod;
  LocalDeployIdentity internal _identityScript;

  /// @notice The Safe that holds the pause and key admin roles of both identity methods. Each method takes its own
  ///         Safe at deployment, and the stories give both the same address, which the deployment allows.
  address internal _identitySafe;

  /// @notice The Ambire implementation the deployment pinned: the stand-in locally, Ambire's own on a fork.
  address internal _ambireImplementation;
  LocalAmbireFactory internal _ambireFactory;
  LocalEntryPoint internal _entryPoint;
  LocalUsdc internal _usdc;

  /*///////////////////////////////////////////////////////////////
                              PEOPLE
  ///////////////////////////////////////////////////////////////*/

  /// @notice Maya's account key, the one she loses.
  Person internal _originalKey;
  /// @notice The new key Maya's fresh device holds.
  Person internal _newKey;
  /// @notice A third key, made when the second is lost too.
  Person internal _secondNewKey;
  /// @notice Maya's guardians.
  Person internal _ana;
  Person internal _ben;
  Person internal _carla;
  /// @notice Maya's hardware wallet.
  Person internal _hardwareWallet;
  /// @notice Maya's passkey, a P-256 private key on her phone.
  uint256 internal _mayaPasskey;
  /// @notice Anyone with a funded wallet who relays, submits or executes.
  address internal _relayer;
  address internal _friend;
  address internal _executor;
  /// @notice A paymaster with a deposit at the entry point.
  address internal _paymaster;
  /// @notice An attacker's key.
  Person internal _attacker;

  /// @notice Who stands behind each credential, by keccak256(method, config).
  mapping(bytes32 _credentialKey => Signer _signer) internal _signers;

  /*///////////////////////////////////////////////////////////////
                              SETUP
  ///////////////////////////////////////////////////////////////*/

  function setUp() public virtual {
    string memory _endpoint = _forkEndpoint();
    if (bytes(_endpoint).length != 0) {
      string memory _url = vm.envOr(_endpoint, string(''));
      if (bytes(_url).length == 0 || !_runsOnForks()) {
        vm.skip(true);
        return;
      }
      vm.createSelectFork(_url, _forkBlock());
    } else {
      vm.warp(_STORY_START);
      vm.roll(23_000_000);
      LocalChain.createStandIns();
    }

    Pins memory _pins = _pinsFor(block.chainid);
    Deployment memory _deployment = _deploy(_pins);
    _ambireImplementation = _pins.ambireImplementation;
    _manager = _deployment.manager;
    _ecdsaMethod = _deployment.ecdsaMethod;
    _passkeyMethod = _deployment.passkeyMethod;
    _action = _deployment.action;

    if (bytes(_endpoint).length == 0) {
      _deployIdentityMethods();
      _ambireFactory = new LocalAmbireFactory();
    } else {
      _ambireFactory = LocalAmbireFactory(_AMBIRE_FACTORY);
    }
    _entryPoint = new LocalEntryPoint();
    _usdc = new LocalUsdc();

    _originalKey = _person('original key');
    _newKey = _person('new key');
    _secondNewKey = _person('second new key');
    _ana = _person('Ana');
    _ben = _person('Ben');
    _carla = _person('Carla');
    _hardwareWallet = _person('Maya hardware wallet');
    _attacker = _person('attacker');
    _mayaPasskey =
      uint256(keccak256('Maya passkey')) % 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    _relayer = _funded('relayer');
    _friend = _funded('friend');
    _executor = _funded('executor bot');
    _paymaster = makeAddr('paymaster');
    _entryPoint.depositTo{value: 1 ether}(_paymaster);
    _checkTheAadhaarSignalAgainstTheVector();
  }

  /// @notice The signal the Aadhaar guardian's device derives from a digest must match the frozen vector, so the walks
  ///         prove with the signal the method checks rather than with a copy that shares its mistakes.
  function _checkTheAadhaarSignalAgainstTheVector() internal view {
    string memory _vector = vm.readFile('test/fixtures/kats/method-aadhaar-proof.json');
    bytes32 _frozenDigest = vm.parseJsonBytes32(_vector, '.vectors[0].input.digest');
    uint256 _frozenSignal = vm.parseUint(vm.parseJsonString(_vector, '.vectors[0].expected.signalHash'));
    assertEq(_aadhaarSignal(_frozenDigest), _frozenSignal, 'fixture: the signal function disagrees with the vector');
  }

  /// @notice The identity methods' deployment, through the real script's local configuration, with one Safe given as
  ///         each method's Safe, so it holds the roles of both.
  function _deployIdentityMethods() internal {
    _identitySafe = makeAddr('identity methods Safe');
    _identityScript = new LocalDeployIdentity();
    IDeployIdentity.Deployment memory _identity = _identityScript.deploy(
      _identityScript.pinsFor(block.chainid),
      IDeployIdentity.Inputs({
        zkPassportMethodSafe: _identitySafe,
        aadhaarMethodSafe: _identitySafe,
        rootAdmin: LocalIdentityRoles.ROOT_ADMIN,
        rootGuardian: LocalIdentityRoles.ROOT_GUARDIAN,
        subVerifierAdmin: LocalIdentityRoles.ROOT_ADMIN
      })
    );
    _aadhaarMethod = AadhaarMethod(address(_identity.aadhaarMethod));
    _zkPassportMethod = ZkPassportMethod(address(_identity.zkPassportMethod));
  }

  /// @notice The chain the stories run on, chosen when the suite runs: the local chain by default, as CI runs it, or
  ///         a fork against Ambire's deployed implementation and factory when INTEGRATION_FORK is `mainnet` or
  ///         `sepolia`, as in `INTEGRATION_FORK=sepolia SEPOLIA_RPC_URL=<url> forge test --match-path
  ///         'test/integration/**'`. A forked story skips when its RPC variable is unset. Choosing at run time keeps
  ///         each story one contract, so the fork runs add nothing to the build.
  function _forkChain() internal view returns (ForkChain _chain) {
    string memory _fork = vm.envOr('INTEGRATION_FORK', string(''));
    bytes32 _name = keccak256(bytes(_fork));
    if (_name == keccak256('mainnet')) _chain = ForkChain.Mainnet;
    else if (_name == keccak256('sepolia')) _chain = ForkChain.Sepolia;
    else require(bytes(_fork).length == 0, IntegrationBase_UnknownFork(_fork));
  }

  /// @notice Whether the story also runs on a fork. On a fork the identity methods are not deployed: their outside
  ///         verifiers there are the real ones, and no story can make a real passport or Aadhaar proof. A story whose
  ///         rule names such a credential answers false and skips on a fork.
  function _runsOnForks() internal pure virtual returns (bool _runs) {
    _runs = true;
  }

  /// @notice The environment variable naming the RPC endpoint of the story's fork, or the empty string on the local
  ///         chain.
  function _forkEndpoint() internal view returns (string memory _variable) {
    ForkChain _chain = _forkChain();
    if (_chain == ForkChain.Mainnet) _variable = 'MAINNET_RPC_URL';
    else if (_chain == ForkChain.Sepolia) _variable = 'SEPOLIA_RPC_URL';
  }

  /// @notice The block a forked story pins, so it does not depend on later chain state.
  function _forkBlock() internal view returns (uint256 _block) {
    _block = _forkChain() == ForkChain.Sepolia ? 11_920_905 : 26_097_000;
  }

  /*///////////////////////////////////////////////////////////////
                         PEOPLE AND ACCOUNTS
  ///////////////////////////////////////////////////////////////*/

  /// @notice A person with a fresh wallet key.
  function _person(string memory _name) internal returns (Person memory _p) {
    (_p.addr, _p.key) = makeAddrAndKey(string.concat(_PEOPLE_PREFIX, _name));
  }

  /// @notice An address with 10 ETH to pay gas and fees.
  function _funded(string memory _name) internal returns (address _addr) {
    _addr = makeAddr(string.concat(_PEOPLE_PREFIX, _name));
    vm.deal(_addr, 10 ether);
  }

  /// @notice Opens a Kohaku Ambire account through the factory, with `_key` at privilege 2, holding 1 ETH.
  function _openAccount(address _key) internal returns (address _account) {
    _account = _ambireFactory.deploy(_accountCode(_key), _accountSalt(_key));
    vm.deal(_account, _OPENING_BALANCE);
  }

  /// @notice Opens an account that also lets the entry point run its ERC-4337 operations.
  function _openAccountWithEntryPoint(address _key) internal returns (address _account) {
    address[] memory _keys = new address[](2);
    bytes32[] memory _values = new bytes32[](2);
    (_keys[0], _values[0]) = (_key, _SIGNER_PRIVILEGE);
    (_keys[1], _values[1]) = (address(_entryPoint), bytes32(uint256(0x7171)));
    _account =
      _ambireFactory.deploy(ActionAmbireProxy.creationCode(_ambireImplementation, _keys, _values), _accountSalt(_key));
    vm.deal(_account, _OPENING_BALANCE);
  }

  /// @notice The proxy creation code of an account whose one key is `_key` at privilege 2.
  function _accountCode(address _key) internal view returns (bytes memory _code) {
    _code = ActionAmbireProxy.creationCode(_ambireImplementation, _key, _SIGNER_PRIVILEGE);
  }

  /// @notice The factory salt this fixture uses for an account, derived from the account's key. The fixture does not
  ///         need it: the creation code already embeds the key and the implementation, so accounts with different
  ///         keys, or one key's plain and entry-point accounts, get different addresses under any one salt. The
  ///         Kohaku wallet itself deploys every account with salt zero.
  function _accountSalt(address _key) internal pure returns (uint256 _salt) {
    _salt = uint256(uint160(_key));
  }

  /// @notice The privilege the account holds for an address.
  function _privilegeOf(address _account, address _addr) internal view returns (bytes32 _privilege) {
    _privilege = IAmbireAccount(_account).privileges(_addr);
  }

  /*///////////////////////////////////////////////////////////////
                             CREDENTIALS
  ///////////////////////////////////////////////////////////////*/

  /// @notice A wallet guardian: the wallet method with the guardian's address.
  function _walletGuardian(Person memory _guardian) internal returns (Credential memory _credential) {
    _credential = Credential(address(_ecdsaMethod), abi.encode(_guardian.addr), bytes32(0));
    Signer storage _signer = _signers[_credentialKey(_credential)];
    _signer.kind = SignerKind.WalletKey;
    _signer.key = _guardian.key;
  }

  /// @notice A smart-wallet guardian: the wallet method with the Safe's address, signed by its owners.
  function _safeGuardian(LocalSafe _safe, uint256[] memory _ownerKeys)
    internal
    returns (Credential memory _credential)
  {
    _credential = Credential(address(_ecdsaMethod), abi.encode(address(_safe)), bytes32(0));
    Signer storage _signer = _signers[_credentialKey(_credential)];
    _signer.kind = SignerKind.SafeOwners;
    _signer.safeOwnerKeys = _ownerKeys;
  }

  /// @notice A passkey: the passkey method with the P-256 public key and the wallet's domain hash.
  function _passkey(uint256 _privateKey) internal returns (Credential memory _credential) {
    (uint256 _x, uint256 _y) = vm.publicKeyP256(_privateKey);
    _credential = Credential(address(_passkeyMethod), abi.encode(_x, _y, sha256(bytes(_PASSKEY_DOMAIN))), bytes32(0));
    Signer storage _signer = _signers[_credentialKey(_credential)];
    _signer.kind = SignerKind.Passkey;
    _signer.key = _privateKey;
  }

  /// @notice An Aadhaar guardian: the identity's nullifier under a seed, and the oldest QR the holder accepts.
  function _aadhaarGuardian(uint256 _nullifier, uint256 _seed, uint256 _freshnessWindow)
    internal
    returns (Credential memory _credential)
  {
    _credential = Credential(address(_aadhaarMethod), abi.encode(_nullifier, _seed, _freshnessWindow), bytes32(0));
    Signer storage _signer = _signers[_credentialKey(_credential)];
    _signer.kind = SignerKind.Aadhaar;
    _signer.aadhaarNullifier = _nullifier;
    _signer.aadhaarSeed = _seed;
    _signer.qrIssuerKey = LocalChain.AADHAAR_ISSUER_KEY;
  }

  /// @notice A passport credential: the identifier zkPassport derives for the passport today.
  function _passport(bytes32 _passportSecret) internal returns (Credential memory _credential) {
    bytes32 _identifier = keccak256(abi.encode(LocalChain.ZKPASSPORT_DERIVATION, _passportSecret));
    _credential = Credential(
      address(_zkPassportMethod), abi.encode(_identifier, _PASSPORT_DOMAIN, _PASSPORT_SCOPE, uint256(0)), bytes32(0)
    );
    Signer storage _signer = _signers[_credentialKey(_credential)];
    _signer.kind = SignerKind.Passport;
    _signer.passportSecret = _passportSecret;
  }

  /// @notice The guardian downloads a fresh Aadhaar QR, signed by `_issuerKey` at `_signedAt`.
  function _downloadQr(Credential memory _credential, bytes32 _issuerKey, uint256 _signedAt) internal {
    Signer storage _signer = _signers[_credentialKey(_credential)];
    _signer.qrIssuerKey = _issuerKey;
    _signer.qrSignedAt = _signedAt;
  }

  /// @notice The key a credential's signer is filed under.
  function _credentialKey(Credential memory _credential) internal pure returns (bytes32 _key) {
    _key = keccak256(abi.encode(_credential.method, _credential.config));
  }

  /*///////////////////////////////////////////////////////////////
                                RULES
  ///////////////////////////////////////////////////////////////*/

  /// @notice A rule over consecutive clauses, with the default salt keccak256(account, place) at each place.
  function _rule(
    address _account,
    uint48 _wait,
    bool _ignoresPause,
    uint8[] memory _clauseThresholds,
    uint256[] memory _clauseSizes,
    Credential[] memory _places
  ) internal pure returns (Rule memory _r) {
    for (uint256 _place; _place < _places.length; ++_place) {
      _places[_place].salt = keccak256(abi.encode(_account, _place));
    }
    _r = Rule(_wait, _ignoresPause, _clauseThresholds, _clauseSizes, _places);
  }

  /// @notice Maya's rule: any 2 of Ana, Ben and Carla, and any 1 of her hardware wallet and her passkey, with a five-
  ///         day wait.
  function _mayaRule(address _account) internal returns (Rule memory _r) {
    _r = _rule(
      _account,
      5 days,
      false,
      _thresholds(2, 1),
      _sizes(3, 2),
      _credentials(
        _walletGuardian(_ana),
        _walletGuardian(_ben),
        _walletGuardian(_carla),
        _walletGuardian(_hardwareWallet),
        _passkey(_mayaPasskey)
      )
    );
  }

  /// @notice Keeps a rule in storage, so every test of a story reads back the rule the backup holds.
  function _keep(Rule storage _slot, Rule memory _r) internal {
    _slot.wait = _r.wait;
    _slot.ignoresPause = _r.ignoresPause;
    _slot.thresholds = _r.thresholds;
    _slot.clauseSizes = _r.clauseSizes;
    delete _slot.places;
    for (uint256 _i; _i < _r.places.length; ++_i) {
      _slot.places.push(_r.places[_i]);
    }
  }

  /// @notice The setup body a rule commits: the wait, the pause choice and each clause's credential hashes.
  function _body(Rule memory _r) internal pure returns (bytes memory _setupBody) {
    IPolicyManager.Clause[] memory _clauses = new IPolicyManager.Clause[](_r.thresholds.length);
    uint256 _place;
    for (uint256 _i; _i < _clauses.length; ++_i) {
      bytes32[] memory _hashes = new bytes32[](_r.clauseSizes[_i]);
      for (uint256 _j; _j < _hashes.length; ++_j) {
        Credential memory _c = _r.places[_place++];
        _hashes[_j] = BindingDigest.credentialCommitment(_c.method, _c.config, _c.salt);
      }
      _clauses[_i] = IPolicyManager.Clause(_r.thresholds[_i], _hashes);
    }
    _setupBody = SetupBody.encode(_r.wait, _r.ignoresPause, _clauses);
  }

  /// @notice The commitment of a rule for an account at a nonce, under the kit's action.
  function _commitment(address _account, uint64 _nonce, Rule memory _r) internal view returns (bytes32 _c) {
    _c = BindingDigest.setupCommitment(_account, address(_action), _nonce, _body(_r));
  }

  function _thresholds(uint8 _a) internal pure returns (uint8[] memory _t) {
    _t = new uint8[](1);
    _t[0] = _a;
  }

  function _thresholds(uint8 _a, uint8 _b) internal pure returns (uint8[] memory _t) {
    _t = new uint8[](2);
    (_t[0], _t[1]) = (_a, _b);
  }

  function _sizes(uint256 _a) internal pure returns (uint256[] memory _s) {
    _s = new uint256[](1);
    _s[0] = _a;
  }

  function _sizes(uint256 _a, uint256 _b) internal pure returns (uint256[] memory _s) {
    _s = new uint256[](2);
    (_s[0], _s[1]) = (_a, _b);
  }

  function _credentials(Credential memory _a) internal pure returns (Credential[] memory _c) {
    _c = new Credential[](1);
    _c[0] = _a;
  }

  function _credentials(Credential memory _a, Credential memory _b) internal pure returns (Credential[] memory _c) {
    _c = new Credential[](2);
    (_c[0], _c[1]) = (_a, _b);
  }

  function _credentials(Credential memory _a, Credential memory _b, Credential memory _d)
    internal
    pure
    returns (Credential[] memory _c)
  {
    _c = new Credential[](3);
    (_c[0], _c[1], _c[2]) = (_a, _b, _d);
  }

  function _credentials(Credential memory _a, Credential memory _b, Credential memory _d, Credential memory _e)
    internal
    pure
    returns (Credential[] memory _c)
  {
    _c = new Credential[](4);
    (_c[0], _c[1], _c[2], _c[3]) = (_a, _b, _d, _e);
  }

  function _credentials(
    Credential memory _a,
    Credential memory _b,
    Credential memory _d,
    Credential memory _e,
    Credential memory _f
  ) internal pure returns (Credential[] memory _c) {
    _c = new Credential[](5);
    (_c[0], _c[1], _c[2], _c[3], _c[4]) = (_a, _b, _d, _e, _f);
  }

  /*///////////////////////////////////////////////////////////////
                           ACCOUNT BATCHES
  ///////////////////////////////////////////////////////////////*/

  /// @notice One account call.
  function _call(address _to, bytes memory _data) internal pure returns (IAmbireRecoveryAction.Transaction memory _t) {
    _t = IAmbireRecoveryAction.Transaction({to: _to, value: 0, data: _data});
  }

  function _batch(IAmbireRecoveryAction.Transaction memory _a)
    internal
    pure
    returns (IAmbireRecoveryAction.Transaction[] memory _calls)
  {
    _calls = new IAmbireRecoveryAction.Transaction[](1);
    _calls[0] = _a;
  }

  function _batch(IAmbireRecoveryAction.Transaction memory _a, IAmbireRecoveryAction.Transaction memory _b)
    internal
    pure
    returns (IAmbireRecoveryAction.Transaction[] memory _calls)
  {
    _calls = new IAmbireRecoveryAction.Transaction[](2);
    (_calls[0], _calls[1]) = (_a, _b);
  }

  function _batch(
    IAmbireRecoveryAction.Transaction memory _a,
    IAmbireRecoveryAction.Transaction memory _b,
    IAmbireRecoveryAction.Transaction memory _c
  ) internal pure returns (IAmbireRecoveryAction.Transaction[] memory _calls) {
    _calls = new IAmbireRecoveryAction.Transaction[](3);
    (_calls[0], _calls[1], _calls[2]) = (_a, _b, _c);
  }

  function _batch(
    IAmbireRecoveryAction.Transaction memory _a,
    IAmbireRecoveryAction.Transaction memory _b,
    IAmbireRecoveryAction.Transaction memory _c,
    IAmbireRecoveryAction.Transaction memory _d
  ) internal pure returns (IAmbireRecoveryAction.Transaction[] memory _calls) {
    _calls = new IAmbireRecoveryAction.Transaction[](4);
    (_calls[0], _calls[1], _calls[2], _calls[3]) = (_a, _b, _c, _d);
  }

  /// @notice The account writes `_value` for `_addr` in its own privilege table.
  function _setPrivilegeCall(address _account, address _addr, bytes32 _value)
    internal
    pure
    returns (IAmbireRecoveryAction.Transaction memory _t)
  {
    _t = _call(_account, abi.encodeCall(IAmbireAccount.setAddrPrivilege, (_addr, _value)));
  }

  /// @notice The account binds the kit's action under KIT_SLOT.
  function _bindKitCall(address _account) internal view returns (IAmbireRecoveryAction.Transaction memory _t) {
    _t = _setPrivilegeCall(_account, _action.KIT_SLOT(), _action.BINDING());
  }

  /// @notice The account removes the kit's binding.
  function _unbindKitCall(address _account) internal view returns (IAmbireRecoveryAction.Transaction memory _t) {
    _t = _setPrivilegeCall(_account, _action.KIT_SLOT(), bytes32(0));
  }

  /// @notice The account commits a rule at a nonce, with an encrypted backup of it.
  function _commitCall(address _account, Rule memory _r, uint64 _nonce)
    internal
    view
    returns (IAmbireRecoveryAction.Transaction memory _t)
  {
    _t = _call(
      address(_manager),
      abi.encodeCall(
        IPolicyManager.commitSetup,
        (address(_action), _commitment(_account, _nonce, _r), _nonce, '', _encryptedBackup(_r))
      )
    );
  }

  /// @notice The account clears its setup, naming the setup nonce it removes, as the holder's client reads it from
  ///         the chain before the key signs.
  function _clearCall(uint64 _nonce) internal view returns (IAmbireRecoveryAction.Transaction memory _t) {
    _t = _call(address(_manager), abi.encodeCall(IPolicyManager.clearSetup, (address(_action), _nonce)));
  }

  /// @notice The account cancels a waiting attempt with its own key, naming the attempt's id, as the holder's client
  ///         reads it from the chain before the key signs.
  function _cancelByOwnerCall(uint64 _attemptId) internal view returns (IAmbireRecoveryAction.Transaction memory _t) {
    _t = _call(address(_manager), abi.encodeCall(IPolicyManager.cancelByOwner, (address(_action), _attemptId)));
  }

  /// @notice A native transfer from the account.
  function _transferCall(address _to, uint256 _amount)
    internal
    pure
    returns (IAmbireRecoveryAction.Transaction memory _t)
  {
    _t = IAmbireRecoveryAction.Transaction({to: _to, value: _amount, data: ''});
  }

  /// @notice The backup the holder's wallet writes beside a commitment: the rule sealed under her password.
  function _encryptedBackup(Rule memory _r) internal pure returns (bytes memory _backup) {
    _backup = abi.encodePacked(keccak256(abi.encode('sealed with the holder password', _body(_r))));
  }

  /*///////////////////////////////////////////////////////////////
                         SENDING ACCOUNT BATCHES
  ///////////////////////////////////////////////////////////////*/

  /// @notice A key signs an account batch at the account's next nonce, in the account-bound form.
  function _keySigns(address _account, uint256 _key, IAmbireRecoveryAction.Transaction[] memory _calls)
    internal
    view
    returns (bytes memory _signature)
  {
    bytes32 _hash =
      keccak256(abi.encode(_account, block.chainid, LocalAmbireAccount(payable(_account)).nonce(), _calls));
    _signature = _signsBound(_account, _key, _hash);
  }

  /// @notice A key signs a hash in Ambire's account-bound form: a signature over the EIP-712 envelope
  ///         AmbireOperation(account, hash), followed by the mode byte 1.
  function _signsBound(address _account, uint256 _key, bytes32 _hash) internal view returns (bytes memory _signature) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_key, _ambireEnvelope(_account, _hash));
    _signature = abi.encodePacked(_r, _s, _v, uint8(1));
  }

  /// @notice The EIP-712 envelope Ambire's signature validator wraps a hash in, binding it to the account and the
  ///         chain: the domain is named Ambire, version 1, with the account as verifying contract and a zero salt.
  function _ambireEnvelope(address _account, bytes32 _hash) internal view returns (bytes32 _envelope) {
    bytes32 _domainSeparator = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)'),
        keccak256('Ambire'),
        keccak256('1'),
        block.chainid,
        _account,
        bytes32(0)
      )
    );
    _envelope = keccak256(
      abi.encodePacked(
        '\x19\x01',
        _domainSeparator,
        keccak256(abi.encode(keccak256('AmbireOperation(address account,bytes32 hash)'), _account, _hash))
      )
    );
  }

  /// @notice A key signs an account batch and a relayer submits it.
  function _keySignsAndRelayerSends(
    address _account,
    Person memory _key,
    IAmbireRecoveryAction.Transaction[] memory _calls
  ) internal {
    bytes memory _signature = _keySigns(_account, _key.key, _calls);
    vm.prank(_relayer);
    IAmbireAccount(_account).execute(_calls, _signature);
  }

  /// @notice A key sends an account batch itself, with no signature.
  function _keySendsItself(address _account, Person memory _key, IAmbireRecoveryAction.Transaction[] memory _calls)
    internal
  {
    vm.prank(_key.addr);
    LocalAmbireAccount(payable(_account)).executeBySender(_calls);
  }

  /// @notice A key signs an ERC-4337 operation that runs the batch, and the paymaster sponsors it.
  function _keySendsSponsoredOperation(
    address _account,
    Person memory _key,
    IAmbireRecoveryAction.Transaction[] memory _calls
  ) internal {
    LocalEntryPoint.PackedUserOperation memory _op = _sponsoredOperation(
      _account, _entryPoint.getNonce(_account, 0), abi.encodeCall(LocalAmbireAccount.executeBySender, (_calls))
    );
    _op.signature = _signsBound(_account, _key.key, _entryPoint.getUserOpHash(_op));
    vm.prank(_relayer);
    _entryPoint.handleOp(_op);
  }

  /// @notice An ERC-4337 v0.7 operation for the account with no signature yet, no init code and no gas fields, whose
  ///         paymasterAndData names the paymaster followed by its two zero gas limits.
  function _sponsoredOperation(address _account, uint256 _nonce, bytes memory _callData)
    internal
    view
    returns (LocalEntryPoint.PackedUserOperation memory _op)
  {
    _op = LocalEntryPoint.PackedUserOperation({
      sender: _account,
      nonce: _nonce,
      initCode: '',
      callData: _callData,
      accountGasLimits: bytes32(0),
      preVerificationGas: 0,
      gasFees: bytes32(0),
      paymasterAndData: abi.encodePacked(_paymaster, uint128(0), uint128(0)),
      signature: ''
    });
  }

  /// @notice The key signs a transfer from the account, and a relayer sends it.
  function _keyTransfers(address _account, Person memory _key, address _to, uint256 _amount) internal {
    _keySignsAndRelayerSends(_account, _key, _batch(_transferCall(_to, _amount)));
  }

  /// @notice Requires the key's signed transfer to move funds from the account.
  function _assertKeyControls(address _account, Person memory _key, string memory _who) internal {
    address _recipient = makeAddr(string.concat('recipient of a transfer signed by ', _who));
    uint256 _before = _recipient.balance;
    _keyTransfers(_account, _key, _recipient, 0.01 ether);
    assertEq(_recipient.balance - _before, 0.01 ether, string.concat(_who, ' moves funds from the account'));
  }

  /// @notice Requires the account to refuse the key's signed transfer.
  function _assertKeyLocked(address _account, Person memory _key) internal {
    bytes memory _signature = _keySigns(_account, _key.key, _batch(_transferCall(_relayer, 0.01 ether)));
    IAmbireRecoveryAction.Transaction[] memory _calls = _batch(_transferCall(_relayer, 0.01 ether));
    vm.prank(_relayer);
    vm.expectRevert(bytes('INSUFFICIENT_PRIVILEGE'));
    IAmbireAccount(_account).execute(_calls, _signature);
  }

  /// @notice The signature the kit's action hands the account: route the batch to the validator bound under KIT_SLOT.
  ///         Anyone can send a hand-built batch to account.execute with it.
  function _kitSignature() internal view returns (bytes memory _signature) {
    _signature = abi.encodePacked(abi.encode(_action.KIT_SLOT(), address(_action), bytes(''), bytes('')), uint8(255));
  }

  /// @notice The holder's key sets up recovery on the account in one relayed batch: the binding, then the commitment at
  ///         nonce 1.
  function _setUpRecovery(address _account, Person memory _key, Rule memory _r) internal {
    _keySignsAndRelayerSends(_account, _key, _batch(_bindKitCall(_account), _commitCall(_account, _r, 1)));
  }

  /*///////////////////////////////////////////////////////////////
                              REQUESTS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The handover payload: install `_installedKey`, remove `_removedKey`.
  function _handover(address _installedKey, address _removedKey) internal pure returns (bytes memory _payload) {
    _payload = abi.encode(IRecoveryAction.Handover(_installedKey, _removedKey));
  }

  /// @notice An empty payment order: nobody is paid.
  function _noPayment() internal pure returns (IPolicyManager.PaymentOrder memory _order) {
    _order = IPolicyManager.PaymentOrder(address(0), 0, address(0));
  }

  /// @notice A request built the way the holder's client builds it: the next attempt id and the current setup nonce
  ///         read from the chain, the rule written out, no proofs yet.
  function _request(
    address _account,
    Rule memory _r,
    bytes memory _payload,
    IPolicyManager.PaymentOrder memory _order,
    uint48 _validUntil
  ) internal view returns (IPolicyManager.AttemptRequest memory _req) {
    IPolicyManager.ActionState memory _state = _manager.stateOf(_account, address(_action));
    _req = IPolicyManager.AttemptRequest({
      account: _account,
      action: address(_action),
      attemptId: _state.nextAttemptId,
      setupNonce: _state.setupNonce,
      setupBody: _body(_r),
      payload: _payload,
      order: _order,
      validUntil: _validUntil,
      proofs: new IPolicyManager.ProofPlace[](0)
    });
  }

  /// @notice The person at a place signs or proves the Approval digest for it, and the proof joins the request.
  function _signApproval(IPolicyManager.AttemptRequest memory _req, Rule memory _r, uint256 _place) internal view {
    _append(_req, _proofPlace(_r, _place, _proofFor(_r.places[_place], _manager.hashApproval(_req, _place))));
  }

  /// @notice A cancel request for one attempt, built the way the holder's client builds it.
  function _cancelRequest(address _account, Rule memory _r, uint64 _attemptId, uint48 _validUntil)
    internal
    view
    returns (IPolicyManager.CancelRequest memory _req)
  {
    _req = IPolicyManager.CancelRequest({
      account: _account,
      action: address(_action),
      attemptId: _attemptId,
      setupNonce: _manager.stateOf(_account, address(_action)).setupNonce,
      setupBody: _body(_r),
      validUntil: _validUntil,
      proofs: new IPolicyManager.ProofPlace[](0)
    });
  }

  /// @notice The person at a place signs or proves the Cancellation digest for it, and the proof joins the cancel
  ///         request.
  function _signCancel(IPolicyManager.CancelRequest memory _req, Rule memory _r, uint256 _place) internal view {
    IPolicyManager.ProofPlace memory _proof =
      _proofPlace(_r, _place, _proofFor(_r.places[_place], _manager.hashCancel(_req, _place)));
    IPolicyManager.ProofPlace[] memory _proofs = new IPolicyManager.ProofPlace[](_req.proofs.length + 1);
    for (uint256 _i; _i < _req.proofs.length; ++_i) {
      _proofs[_i] = _req.proofs[_i];
    }
    _proofs[_req.proofs.length] = _proof;
    _req.proofs = _proofs;
  }

  /// @notice A filled place: the credential written out and the proof.
  function _proofPlace(Rule memory _r, uint256 _place, bytes memory _proof)
    internal
    pure
    returns (IPolicyManager.ProofPlace memory _p)
  {
    Credential memory _c = _r.places[_place];
    _p = IPolicyManager.ProofPlace({place: _place, method: _c.method, config: _c.config, salt: _c.salt, proof: _proof});
  }

  /// @notice Adds a filled place at the end of a request's proofs.
  function _append(IPolicyManager.AttemptRequest memory _req, IPolicyManager.ProofPlace memory _proof) internal pure {
    IPolicyManager.ProofPlace[] memory _proofs = new IPolicyManager.ProofPlace[](_req.proofs.length + 1);
    for (uint256 _i; _i < _req.proofs.length; ++_i) {
      _proofs[_i] = _req.proofs[_i];
    }
    _proofs[_req.proofs.length] = _proof;
    _req.proofs = _proofs;
  }

  /// @notice A copy of a request, so a story can change one field of what the approvers signed.
  function _copy(IPolicyManager.AttemptRequest memory _req)
    internal
    pure
    returns (IPolicyManager.AttemptRequest memory _out)
  {
    _out = abi.decode(abi.encode(_req), (IPolicyManager.AttemptRequest));
  }

  /// @notice A submitter sends the request.
  function _submits(address _submitter, IPolicyManager.AttemptRequest memory _req) internal {
    vm.prank(_submitter);
    _manager.startAttempt(_req);
  }

  /// @notice A submitter sends the cancel request.
  function _submitsCancel(address _submitter, IPolicyManager.CancelRequest memory _req) internal {
    vm.prank(_submitter);
    _manager.cancelByProofs(_req);
  }

  /// @notice Anyone calls executeHandover with the approved payload.
  function _executes(address _caller, address _account, bytes memory _payload) internal {
    vm.prank(_caller);
    _action.executeHandover(_account, _payload);
  }

  /// @notice The account's attempt record under the kit's action.
  function _attempt(address _account) internal view returns (IPolicyManager.Attempt memory _a) {
    _a = _manager.stateOf(_account, address(_action)).attempt;
  }

  /// @notice The account's state under the kit's action.
  function _stateOf(address _account) internal view returns (IPolicyManager.ActionState memory _s) {
    _s = _manager.stateOf(_account, address(_action));
  }

  /*///////////////////////////////////////////////////////////////
                               PROOFS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The proof the person behind a credential produces for a digest.
  function _proofFor(Credential memory _credential, bytes32 _digest) internal view returns (bytes memory _proof) {
    Signer storage _signer = _signers[_credentialKey(_credential)];
    SignerKind _kind = _signer.kind;
    if (_kind == SignerKind.WalletKey) return _walletSignature(_signer.key, _digest);
    if (_kind == SignerKind.SafeOwners) return _safeSignature(_credential, _signer.safeOwnerKeys, _digest);
    if (_kind == SignerKind.Passkey) return _passkeyAssertion(_signer.key, _digest);
    if (_kind == SignerKind.Aadhaar) return _aadhaarProof(_signer, _digest);
    if (_kind == SignerKind.Passport) return _passportProof(_signer.passportSecret, _digest);
    revert IntegrationBase_NobodyStandsBehindTheCredential();
  }

  /// @notice A wallet's 65-byte signature over the digest.
  function _walletSignature(uint256 _key, bytes32 _digest) internal pure returns (bytes memory _signature) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_key, _digest);
    _signature = abi.encodePacked(_r, _s, _v);
  }

  /// @notice The Safe owners' signatures over Safe's message hash of the digest, sorted by owner.
  function _safeSignature(Credential memory _credential, uint256[] memory _ownerKeys, bytes32 _digest)
    internal
    view
    returns (bytes memory _signatures)
  {
    LocalSafe _safe = LocalSafe(abi.decode(_credential.config, (address)));
    _signatures = _ownersSign(_ownerKeys, _safe.messageHash(_digest));
  }

  /// @notice Owner signatures over a hash, sorted by owner address as a Safe requires.
  function _ownersSign(uint256[] memory _ownerKeys, bytes32 _hash) internal pure returns (bytes memory _signatures) {
    uint256[] memory _keys = new uint256[](_ownerKeys.length);
    for (uint256 _i; _i < _keys.length; ++_i) {
      _keys[_i] = _ownerKeys[_i];
    }
    for (uint256 _i; _i < _keys.length; ++_i) {
      for (uint256 _j = _i + 1; _j < _keys.length; ++_j) {
        if (vm.addr(_keys[_j]) < vm.addr(_keys[_i])) (_keys[_i], _keys[_j]) = (_keys[_j], _keys[_i]);
      }
    }
    for (uint256 _i; _i < _keys.length; ++_i) {
      (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_keys[_i], _hash);
      _signatures = abi.encodePacked(_signatures, _r, _s, _v);
    }
  }

  /// @notice A WebAuthn assertion of the passkey over the digest, user present and verified.
  function _passkeyAssertion(uint256 _key, bytes32 _digest) internal pure returns (bytes memory _proof) {
    bytes memory _authenticatorData = abi.encodePacked(sha256(bytes(_PASSKEY_DOMAIN)), bytes1(0x05), bytes4(0));
    bytes memory _clientData = abi.encodePacked(
      '{"type":"webauthn.get","challenge":"',
      Base64.encodeURL(abi.encodePacked(_digest)),
      '","origin":"https://wallet.example","crossOrigin":false}'
    );
    (bytes32 _r, bytes32 _s) = vm.signP256(_key, sha256(abi.encodePacked(_authenticatorData, sha256(_clientData))));
    _proof = abi.encode(_authenticatorData, _clientData, uint256(_r), uint256(_s));
  }

  /// @notice An Anon Aadhaar proof over the digest from the guardian's current QR.
  function _aadhaarProof(Signer storage _signer, bytes32 _digest) internal view returns (bytes memory _proof) {
    uint256[9] memory _inputs;
    _inputs[0] = uint256(_signer.qrIssuerKey);
    _inputs[1] = _signer.aadhaarNullifier;
    _inputs[2] = _signer.qrSignedAt == 0 ? block.timestamp - (block.timestamp % 1 hours) : _signer.qrSignedAt;
    _inputs[7] = _signer.aadhaarSeed;
    _inputs[8] = _aadhaarSignal(_digest);
    uint256[2] memory _a;
    uint256[2][2] memory _b;
    uint256[2] memory _c;
    _proof = abi.encode(_a, _b, _c, _inputs);
  }

  /// @notice The revert a request earns when the proof at a place does not verify under its method.
  function _proofRejected(uint256 _place, address _method) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IPolicyManager.PolicyManager_ProofRejected.selector, _place, _method);
  }

  /// @notice The signal an Anon Aadhaar proof binds for a digest: its keccak256 hash shifted right by three bits.
  function _aadhaarSignal(bytes32 _digest) internal pure returns (uint256 _signal) {
    _signal = uint256(keccak256(abi.encodePacked(uint256(_digest)))) >> 3;
  }

  /// @notice A zkPassport proof that the passport's holder approves the digest.
  function _passportProof(bytes32 _passportSecret, bytes32 _digest) internal pure returns (bytes memory _proof) {
    bytes32[] memory _publicInputs = new bytes32[](4);
    _publicInputs[0] = keccak256('certificate registry root');
    _publicInputs[3] = keccak256('scoped nullifier');
    IZkPassportRootVerifier.ProofVerificationData memory _data = IZkPassportRootVerifier.ProofVerificationData({
      vkeyHash: keccak256('outer circuit'), proof: abi.encode(_passportSecret), publicInputs: _publicInputs
    });
    _proof = abi.encode(_data, abi.encode(vm.toString(_digest)));
  }
}
