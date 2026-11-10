// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ERC165} from '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {IPolicyMethod} from 'interfaces/IPolicyMethod.sol';
import {IPolicyMethodAdmin} from 'interfaces/IPolicyMethodAdmin.sol';
import {IPolicyMethodPause} from 'interfaces/IPolicyMethodPause.sol';
import {IPolicyMethodStop} from 'contracts/methods/roles/IPolicyMethodStop.sol';

/// @title PolicyMethodRoles
/// @author defi-wonderland
/// @notice This contract carries the two roles of an identity method. The pause holder is the `Ownable2Step`
///         owner and turns the method's stop on and off. The key admin is a separate role and replaces the
///         method's trusted keys. A holder who renounces one role leaves the other role in place.
/// @dev The trusted keys are the outside values the method's verdict depends on, such as the hash of an
///      identity issuer's public key, or the addresses and versions of a proof system's verifier. Each
///      inheriting method fixes how many words it stores and what each word means. That is why they are a list
///      and not one key. The key admin is the address allowed to replace that list. Once the key admin
///      renounces, no address can ever become key admin again, and the trusted keys stay as they are for good.
///      The contract exposes the `IPolicyMethodPause` selectors and advertises its interface id. It does not
///      inherit `IPolicyMethodPause` as a Solidity base. `Pausable` already declares the same `Paused(address)`
///      and `Unpaused(address)` events, and a second declaration would not compile. The inheriting method
///      implements `verify` and the `_validateTrustedKeys` hook.
///      An inheriting method must not override, and must not call outside this base's own flow, these
///      OpenZeppelin members: `owner`, `pendingOwner`, `transferOwnership`, `renounceOwnership`,
///      `_transferOwnership`, `paused`, `_pause`, `_unpause` and `_msgSender`. The pause holder's rules, the
///      stop, the key admin's caller check and the `OwnershipTransferStarted`, `OwnershipTransferred`, `Paused`
///      and `Unpaused` events all depend on them. A child that changed or bypassed one of them could move a
///      role or the stop without the checks or the events that holders and monitors rely on.
abstract contract PolicyMethodRoles is
  ERC165,
  Pausable,
  Ownable2Step,
  IPolicyMethod,
  IPolicyMethodAdmin,
  IPolicyMethodStop
{
  /*///////////////////////////////////////////////////////////////
                          STATE VARIABLES
  ///////////////////////////////////////////////////////////////*/

  /// @notice The address that can replace this method's trusted keys. It is address(0) after the key admin
  ///         renounces.
  address private _keyAdmin;

  /// @notice The address that becomes the key admin when it accepts. It is address(0) when no transfer is open.
  address private _pendingKeyAdmin;

  /// @notice The trusted keys this method stores today: the outside values its verdict depends on, such as the
  ///         hash of an identity issuer's public key or a verifier's address and version. The inheriting method
  ///         fixes how many words there are and what each word means. The key admin can replace the list.
  bytes32[] private _storedKeys;

  /// @notice The module's human-readable name. The constructor sets it.
  string private _name;

  /// @notice The module's semantic version. The constructor sets it.
  string private _version;

  /*///////////////////////////////////////////////////////////////
                             MODIFIERS
  ///////////////////////////////////////////////////////////////*/

  /// @notice Only the current key admin passes this check. After the key admin renounces, no caller passes.
  modifier onlyAdmin() {
    require(
      _keyAdmin != address(0) && _msgSender() == _keyAdmin, PolicyMethodRoles_AdminUnauthorizedAccount(_msgSender())
    );
    _;
  }

  /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ///////////////////////////////////////////////////////////////*/

  /// @notice The constructor sets the pause holder, the key admin, the initial keys, the name and the version.
  /// @dev `Ownable` refuses a zero initial owner. The constructor runs the initial keys through the same
  ///      `_validateTrustedKeys` hook that `setTrustedKeys` runs, before it stores them. An invalid initial set
  ///      therefore reverts the deployment. Like `setTrustedKeys`, it hands the hook an independent copy of the
  ///      list, so the hook cannot change the words that get stored.
  /// @param _initialOwner The pause holder.
  /// @param _initialAdmin The key admin. The constructor refuses the zero address.
  /// @param _initialKeys The keys the method trusts from deployment.
  /// @param _moduleName The module's human-readable name.
  /// @param _moduleVersion The module's semantic version.
  constructor(
    address _initialOwner,
    address _initialAdmin,
    bytes32[] memory _initialKeys,
    string memory _moduleName,
    string memory _moduleVersion
  ) Ownable(_initialOwner) {
    require(_initialAdmin != address(0), PolicyMethodRoles_AdminInvalidAdmin(_initialAdmin));
    // The hook checks its own copy, so a hook that writes its argument cannot change the list stored below.
    bytes32[] memory _candidate = new bytes32[](_initialKeys.length);
    for (uint256 _i; _i < _initialKeys.length; ++_i) {
      _candidate[_i] = _initialKeys[_i];
    }
    _validateTrustedKeys(_candidate);
    _keyAdmin = _initialAdmin;
    _storedKeys = _initialKeys;
    _name = _moduleName;
    _version = _moduleVersion;
    emit AdminTransferred(address(0), _initialAdmin);
    emit TrustedKeysUpdated(new bytes32[](0), _initialKeys);
  }

  /*///////////////////////////////////////////////////////////////
                         EXTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPolicyMethodStop
  /// @dev It has the selector of `IPolicyMethodPause.pause`. It reverts with `EnforcedPause` when the method is
  ///      already stopped.
  function pause() external onlyOwner {
    _pause();
  }

  /// @inheritdoc IPolicyMethodStop
  /// @dev It has the selector of `IPolicyMethodPause.unpause`. It reverts with `ExpectedPause` when the method
  ///      is not stopped.
  function unpause() external onlyOwner {
    _unpause();
  }

  /// @inheritdoc IPolicyMethodAdmin
  function setTrustedKeys(bytes32[] calldata _trustedKeys) external onlyAdmin {
    _validateTrustedKeys(_trustedKeys);
    bytes32[] memory _previous = _storedKeys;
    _storedKeys = _trustedKeys;
    emit TrustedKeysUpdated(_previous, _trustedKeys);
  }

  /// @inheritdoc IPolicyMethodAdmin
  function transferAdmin(address _newAdmin) external onlyAdmin {
    _pendingKeyAdmin = _newAdmin;
    emit AdminTransferOffered(_msgSender(), _newAdmin);
  }

  /// @inheritdoc IPolicyMethodAdmin
  function acceptAdmin() external {
    require(
      _pendingKeyAdmin != address(0) && _msgSender() == _pendingKeyAdmin,
      PolicyMethodRoles_AdminUnauthorizedAccount(_msgSender())
    );
    address _previous = _keyAdmin;
    _keyAdmin = _msgSender();
    delete _pendingKeyAdmin;
    emit AdminTransferred(_previous, _msgSender());
  }

  /// @inheritdoc IPolicyMethodAdmin
  /// @dev It also cancels an open transfer. After it, no address can ever become key admin again, and the
  ///      trusted keys stay as they are for good.
  function renounceAdmin() external onlyAdmin {
    delete _pendingKeyAdmin;
    delete _keyAdmin;
    emit AdminRenounced(_msgSender());
  }

  /// @inheritdoc IPolicyMethodAdmin
  function pendingAdmin() external view returns (address _pendingAdmin) {
    _pendingAdmin = _pendingKeyAdmin;
  }

  /// @inheritdoc IPolicyMethod
  function trustedParties()
    external
    view
    returns (
      address _admin,
      address _pendingAdmin,
      bytes32[] memory _trustedKeys,
      address _pauseHolder,
      address _pendingPauseHolder
    )
  {
    _admin = _keyAdmin;
    _pendingAdmin = _pendingKeyAdmin;
    _trustedKeys = _storedKeys;
    _pauseHolder = owner();
    _pendingPauseHolder = pendingOwner();
  }

  /// @inheritdoc IPolicyMethod
  function name() external view returns (string memory _moduleName) {
    _moduleName = _name;
  }

  /// @inheritdoc IPolicyMethod
  function version() external view returns (string memory _moduleVersion) {
    _moduleVersion = _version;
  }

  /*///////////////////////////////////////////////////////////////
                          PUBLIC FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @inheritdoc Ownable2Step
  /// @dev It refuses the call when no transfer is open. A caller at address(0) therefore cannot accept a role
  ///      that nobody offered.
  function acceptOwnership() public override {
    require(pendingOwner() != address(0), OwnableUnauthorizedAccount(_msgSender()));
    super.acceptOwnership();
  }

  /// @inheritdoc IPolicyMethod
  function supportsInterface(bytes4 _interfaceId)
    public
    view
    override(ERC165, IPolicyMethod)
    returns (bool _supported)
  {
    _supported = _interfaceId == type(IPolicyMethod).interfaceId || _interfaceId == type(IPolicyMethodPause).interfaceId
      || _interfaceId == type(IPolicyMethodAdmin).interfaceId || super.supportsInterface(_interfaceId);
  }

  /*///////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
  ///////////////////////////////////////////////////////////////*/

  /// @inheritdoc Ownable
  /// @dev After `renounceOwnership` it refuses every caller, including address(0). Nobody can then pause,
  ///      unpause or move the role. A stop that is on when the owner renounces stays on permanently.
  function _checkOwner() internal view override {
    address _currentOwner = owner();
    require(_currentOwner != address(0) && _currentOwner == _msgSender(), OwnableUnauthorizedAccount(_msgSender()));
  }

  /// @notice Returns one stored trusted key. An inheriting method reads the words it needs through this
  ///         getter, one at a time, so it never copies the whole list and makes no external call to itself.
  /// @dev It reads the list's length for the bounds check and then the one word, never the other words. An
  ///      index at or past the stored length reverts with the array bounds panic (0x32). An inheriting
  ///      method asks only for indexes its own `_validateTrustedKeys` override fixed. That override must not
  ///      call this getter: the constructor runs it before the keys are stored, so storage is still empty.
  /// @param _index The position of the word in the stored list.
  /// @return _key The stored word at `_index`.
  function _trustedKey(uint256 _index) internal view returns (bytes32 _key) {
    _key = _storedKeys[_index];
  }

  /// @notice The inheriting method checks a candidate trusted-key set here before the contract stores it.
  /// @dev An override must revert on a set the method refuses. `setTrustedKeys` and the constructor both run
  ///      it. The constructor's call runs inside this base's constructor, before the inheriting contract's own
  ///      constructor body. At that point an immutable of the inheriting contract is not assigned yet and reads
  ///      as zero, and so does storage the inheriting contract sets. An override therefore relies on constants
  ///      and its `_keys` argument. It may read an immutable or storage that the inheriting contract sets only
  ///      when it reads the zero value as the constructor's call. It must not write `_keys`: the hook receives
  ///      a copy of the list that gets stored, so a write changes nothing stored and only defeats the check.
  /// @param _keys The candidate trusted keys.
  function _validateTrustedKeys(bytes32[] memory _keys) internal view virtual;
}
