// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPolicyManager} from 'interfaces/IPolicyManager.sol';

import {IAmbireAccount} from 'contracts/actions/ambire/IAmbireAccount.sol';
import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';

import {IntegrationBase} from 'test/integration/base/IntegrationBase.sol';
import {LocalAmbireAccount} from 'test/integration/base/LocalAmbire.sol';
import {ActionAmbireProxy} from 'test/utils/ActionAmbireProxy.sol';

/// @notice A holder who still has their original key sets up recovery on their account in one batch: the kit's binding,
///         then the commitment to Maya's rule. The story is told once; each kind below says how the holder's batch
///         reaches the account.
abstract contract SetUpRecovery is IntegrationBase {
  /// @notice The holder's account.
  address internal _account;

  function setUp() public virtual override {
    super.setUp();
    _account = _holdersAccount();
  }

  /*///////////////////////////////////////////////////////////////
                         WHAT EACH KIND SAYS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The holder's account, the original key at privilege 2, before recovery is set up.
  function _holdersAccount() internal virtual returns (address _holderAccount) {
    _holderAccount = _openAccount(_originalKey.addr);
  }

  /// @notice The holder sends a batch to the account, signed with the original key.
  function _holderSends(IAmbireRecoveryAction.Transaction[] memory _calls) internal virtual;

  /*///////////////////////////////////////////////////////////////
                              THE WALK
  ///////////////////////////////////////////////////////////////*/

  /// @notice One batch binds the kit and commits Maya's rule, writing the kit's entry and keeping the holder's key at
  ///         its value, the holder's key keeps working as before, and a recovery works from then on. The holder gets a
  ///         way back into the account without giving up their key.
  function test_WhenTheHolderSetsUpRecoveryInOneBatch() external {
    // The holder writes out Maya's rule and its encrypted backup off chain.
    Rule memory _r = _mayaRule(_account);

    // The holder signs one batch, the kit's binding then the commitment at nonce 1, and it reaches the account.
    _holderSends(_batch(_bindKitCall(_account), _commitCall(_account, _r, 1)));

    // The batch wrote the kit's entry, the binding that routes the account to this action, and left the holder's key
    // at the signer value 2 a fresh account gives it.
    assertEq(_privilegeOf(_account, _action.KIT_SLOT()), _action.BINDING(), 'KIT_SLOT holds the binding');
    assertEq(
      _privilegeOf(_account, _action.KIT_SLOT()),
      keccak256(abi.encode(address(_action), bytes(''))),
      'the binding names this action with empty data'
    );
    assertEq(_privilegeOf(_account, _originalKey.addr), bytes32(uint256(2)), 'the holder key keeps its value');

    // Everyday use is unchanged: an ordinary transfer signed with the original key still runs.
    uint256 _friendBalance = _friend.balance;
    _holderSends(_batch(_transferCall(_friend, 0.1 ether)));
    assertEq(_friend.balance - _friendBalance, 0.1 ether, 'the transfer ran');
    _assertKeyControls(_account, _originalKey, 'the original key');

    // Recovery is set up: Ben, Carla and the passkey can hand it to a new key once the wait passes.
    bytes memory _payload = _approversOpenHandover(_account, _r, _newKey.addr);
    skip(_r.wait);
    _executes(_executor, _account, _payload);
    _assertKeyControls(_account, _newKey, 'the new key');
  }

  /*///////////////////////////////////////////////////////////////
                              UTILITIES
  ///////////////////////////////////////////////////////////////*/

  /// @notice Ben, Carla and Maya's passkey approve handing the account from the original key to `_newKey`, and a friend
  ///         submits.
  function _approversOpenHandover(address _holderAccount, Rule memory _r, address _newKey)
    internal
    returns (bytes memory _payload)
  {
    _payload = _handover(_newKey, _originalKey.addr);
    IPolicyManager.AttemptRequest memory _req =
      _request(_holderAccount, _r, _payload, _noPayment(), uint48(block.timestamp + 24 hours));
    _signApproval(_req, _r, 1);
    _signApproval(_req, _r, 2);
    _signApproval(_req, _r, 4);
    _submits(_friend, _req);
  }
}

/// @notice The holder signs each batch with the original key and a relayer sends it to account.execute. This kind also
///         carries the cases where the setup must hold even if something is off, and the trade-offs the kit accepts.
contract SetUpRecoveryWithARelayedSignature is SetUpRecovery {
  function _holderSends(IAmbireRecoveryAction.Transaction[] memory _calls) internal override {
    // The original key signs the batch and a relayer submits it.
    _keySignsAndRelayerSends(_account, _originalKey, _calls);
  }

  /*///////////////////////////////////////////////////////////////
                              EVEN IF
  ///////////////////////////////////////////////////////////////*/

  /// @notice An account running another Ambire implementation cannot have recovery set up: the commit refuses and the
  ///         whole batch reverts, so KIT_SLOT stays empty. An action that does not serve the account could never run a
  ///         recovery on it, so the holder must not be told recovery is set up.
  function test_WhenTheAccountRunsAnotherImplementation() external {
    // The holder's account is a proxy over another Ambire implementation than the one the kit pins.
    address _otherImplementation = address(new LocalAmbireAccount());
    address _otherAccount = _ambireFactory.deploy(
      ActionAmbireProxy.creationCode(_otherImplementation, _originalKey.addr, _SIGNER_PRIVILEGE),
      _accountSalt(_originalKey.addr)
    );
    Rule memory _r = _mayaRule(_otherAccount);

    // The original key signs the setup batch and a relayer sends it: the commit refuses the action.
    IAmbireRecoveryAction.Transaction[] memory _calls =
      _batch(_bindKitCall(_otherAccount), _commitCall(_otherAccount, _r, 1));
    bytes memory _signature = _keySigns(_otherAccount, _originalKey.key, _calls);
    vm.prank(_relayer);
    vm.expectPartialRevert(IPolicyManager.PolicyManager_ActionDoesNotServeAccount.selector);
    IAmbireAccount(_otherAccount).execute(_calls, _signature);

    // KIT_SLOT stays empty and no setup was written.
    assertEq(_privilegeOf(_otherAccount, _action.KIT_SLOT()), bytes32(0), 'KIT_SLOT stays empty');
    assertEq(_stateOf(_otherAccount).setupNonce, 0, 'no setup was written');
  }

  /// @notice The original key's own address delegates to the pinned Ambire code under EIP-7702 and tries to set up
  ///         recovery on itself. The commit refuses, because the original key would keep signing for that address after
  ///         any handover, and KIT_SLOT stays empty.
  function test_WhenTheHoldersAddressDelegatesToAmbireCode() external {
    // The original key signs an EIP-7702 authorization delegating its address to the pinned Ambire implementation.
    vm.signAndAttachDelegation(_ambireImplementation, _originalKey.key);
    // The original key calls its own address to write itself at privilege 2.
    vm.prank(_originalKey.addr);
    IAmbireAccount(_originalKey.addr).setAddrPrivilege(_originalKey.addr, _SIGNER_PRIVILEGE);
    Rule memory _r = _mayaRule(_originalKey.addr);

    // The original key sends the setup batch from its own address: the commit refuses the action.
    IAmbireRecoveryAction.Transaction[] memory _calls =
      _batch(_bindKitCall(_originalKey.addr), _commitCall(_originalKey.addr, _r, 1));
    vm.prank(_originalKey.addr);
    vm.expectPartialRevert(IPolicyManager.PolicyManager_ActionDoesNotServeAccount.selector);
    LocalAmbireAccount(payable(_originalKey.addr)).executeBySender(_calls);

    // KIT_SLOT stays empty and no setup was written.
    assertEq(_privilegeOf(_originalKey.addr, _action.KIT_SLOT()), bytes32(0), 'KIT_SLOT stays empty');
    assertEq(_stateOf(_originalKey.addr).setupNonce, 0, 'no setup was written');
  }

  /*///////////////////////////////////////////////////////////////
                             TRADE-OFFS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The kit accepts a rule with no wait, and an attempt under it is spent in the block that opened it. Such a
  ///         holder has no window to notice and cancel.
  function test_WhenTheRuleHasNoWait() external {
    // The holder sets up recovery on the account with Maya's approvers and a wait of zero.
    Rule memory _r = _rule(
      _account,
      0,
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
    _setUpRecovery(_account, _originalKey, _r);

    // The approvers open an attempt handing the account to the new key.
    bytes memory _payload = _approversOpenHandover(_account, _r, _newKey.addr);

    // In the same block, anyone executes it, and the new key takes the account.
    _executes(_executor, _account, _payload);
    _assertKeyControls(_account, _newKey, 'the new key');
    _assertKeyLocked(_account, _originalKey);
  }
}

/// @notice The original key calls executeBySender on the account itself, paying its own gas.
contract SetUpRecoveryWhenTheKeySendsItself is SetUpRecovery {
  function _holderSends(IAmbireRecoveryAction.Transaction[] memory _calls) internal override {
    // The original key sends the batch itself.
    vm.deal(_originalKey.addr, 0.05 ether);
    _keySendsItself(_account, _originalKey, _calls);
  }
}

/// @notice The original key signs an ERC-4337 operation and a paymaster sponsors it, so the holder spends no ETH on
///         gas.
contract SetUpRecoveryThroughASponsoredOperation is SetUpRecovery {
  function _holdersAccount() internal override returns (address _holderAccount) {
    _holderAccount = _openAccountWithEntryPoint(_originalKey.addr);
  }

  function _holderSends(IAmbireRecoveryAction.Transaction[] memory _calls) internal override {
    // The original key signs the operation and the paymaster sponsors it.
    _keySendsSponsoredOperation(_account, _originalKey, _calls);
  }
}

/// @notice The holder's account is not deployed yet. Its first batch, the setup, goes through the factory, which
///         deploys the account and runs the batch in one transaction.
contract SetUpRecoveryForACounterfactualAccount is SetUpRecovery {
  function _holdersAccount() internal override returns (address _holderAccount) {
    // The wallet computes the account's CREATE2 address itself, as the real factory has no view for it.
    _holderAccount = address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              bytes1(0xff),
              address(_ambireFactory),
              _accountSalt(_originalKey.addr),
              keccak256(_accountCode(_originalKey.addr))
            )
          )
        )
      )
    );
    // The holder has already received ETH at the account's address.
    vm.deal(_holderAccount, _OPENING_BALANCE);
  }

  function _holderSends(IAmbireRecoveryAction.Transaction[] memory _calls) internal override {
    if (_account.code.length != 0) {
      // The original key signs the batch and a relayer submits it.
      _keySignsAndRelayerSends(_account, _originalKey, _calls);
      return;
    }
    // The original key signs the first batch at nonce 0, and a relayer has the factory deploy the account and run it.
    bytes memory _signature = _firstBatchSignature(_calls);
    vm.prank(_relayer);
    _ambireFactory.deployAndExecute(
      _accountCode(_originalKey.addr), _accountSalt(_originalKey.addr), _calls, _signature
    );
  }

  /// @notice The original key's account-bound signature over a batch for the not-yet-deployed account, at nonce 0.
  function _firstBatchSignature(IAmbireRecoveryAction.Transaction[] memory _calls)
    internal
    view
    returns (bytes memory _signature)
  {
    bytes32 _hash = keccak256(abi.encode(_account, block.chainid, uint256(0), _calls));
    _signature = _signsBound(_account, _originalKey.key, _hash);
  }
}
