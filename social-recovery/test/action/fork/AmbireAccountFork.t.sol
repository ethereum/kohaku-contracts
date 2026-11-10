// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test, Vm} from 'forge-std/Test.sol';
import {IRecoveryAction} from 'interfaces/IRecoveryAction.sol';
import {IAmbireAccount} from 'contracts/actions/ambire/IAmbireAccount.sol';
import {IAmbireRecoveryAction} from 'contracts/actions/ambire/IAmbireRecoveryAction.sol';
import {
  ActionForkApprovingValidator,
  ActionForkCountingTarget,
  ActionForkFallbackHandler,
  ActionForkRefusingTarget,
  IActionAmbireSender,
  IActionAmbireFactory
} from 'test/utils/ActionAmbireForkAbi.sol';
import {ActionAmbireProxy} from 'test/utils/ActionAmbireProxy.sol';
import {ActionForkBlocks} from 'test/utils/ActionForkBlocks.sol';

/// @notice Checks, on a fork of mainnet and of Sepolia, what the action assumes about Ambire's
///         deployed account at kohaku-commons commit 29227cc. A factory-built account must be the
///         proxy the fit check accepts with its one signer key privileged, a failing call must
///         revert execute with that call's own revert data, and a privilege write must emit
///         LogPrivilegeChanged(address indexed, bytes32). The SDK decodes errors and alerts on
///         privilege changes by these shapes. Every privilege read, privilege write, batch and
///         event topic goes through the action's own compiled IAmbireAccount, so a selector or an
///         event layout copied wrongly into it breaks these tests against the deployed account.
/// @dev Each test skips cleanly when its endpoint is unset.
contract AmbireAccountForkTest is Test, ActionForkBlocks {
  string internal constant _ACTION_ARTIFACT = 'AmbireRecoveryAction.sol:AmbireRecoveryAction';
  /// @notice The pinned implementation, kohaku-commons src/consts/deploy.ts line 1.
  address internal constant _AMBIRE_IMPLEMENTATION = 0x0F2AA7bcda3d9D210dF69a394b6965CB2566c828;
  /// @notice Ambire's account factory, kohaku-commons src/consts/deploy.ts line 2.
  address internal constant _AMBIRE_FACTORY = 0x26cE6745A633030A6faC5e64e41D21fb6246dc2d;
  /// @notice The key value the extension writes, kohaku-commons src/interfaces/keystore.ts line 104.
  bytes32 internal constant _SIGNER_VALUE = bytes32(uint256(2));
  /// @notice The privilege key whose entry names the deployed implementation's fallback handler.
  address internal constant _FALLBACK_HANDLER_SLOT = address(0x6969);

  IRecoveryAction internal _action;
  address internal _signer;

  /// @notice Forks at `_block`, a fixed block, so the test does not depend on later chain state, and
  ///         deploys the action. Skips when the endpoint is unset.
  function _fork(string memory _envName, uint256 _block) internal {
    string memory _url = vm.envOr(_envName, string(''));
    if (bytes(_url).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(_url, _block);
    address _mgr = makeAddr('forkPolicyManager');
    vm.etch(_mgr, hex'00');
    _action = IRecoveryAction(deployCode(_ACTION_ARTIFACT, abi.encode(_mgr, _AMBIRE_IMPLEMENTATION)));
    _signer = makeAddr('forkSigner');
  }

  function _buildAccount(address _impl) internal returns (IAmbireAccount _acct) {
    bytes memory _creation = ActionAmbireProxy.creationCode(_impl, _signer, _SIGNER_VALUE);
    address _expected = ActionAmbireProxy.create2Address(_AMBIRE_FACTORY, _creation, 0);
    address _deployed = IActionAmbireFactory(_AMBIRE_FACTORY).deploy(_creation, 0);
    assertEq(_deployed, _expected, 'the create2 address the factory, the creation code and salt zero produce');
    _acct = IAmbireAccount(_deployed);
  }

  function _one(address _to, bytes memory _data)
    internal
    pure
    returns (IAmbireRecoveryAction.Transaction[] memory _calls)
  {
    _calls = new IAmbireRecoveryAction.Transaction[](1);
    _calls[0] = IAmbireRecoveryAction.Transaction({to: _to, value: 0, data: _data});
  }

  /// @notice The signer key runs one call on the account itself that writes `_value` for `_addr`,
  ///         encoded through the action's IAmbireAccount.
  function _selfWrite(IAmbireAccount _acct, address _addr, bytes32 _value) internal {
    vm.prank(_signer);
    IActionAmbireSender(address(_acct))
      .executeBySender(_one(address(_acct), abi.encodeCall(IAmbireAccount.setAddrPrivilege, (_addr, _value))));
  }

  /*///////////////////////////////////////////////////////////////
                       FACTORY-BUILT ACCOUNT
  ///////////////////////////////////////////////////////////////*/

  function _checkBuiltAccount() internal {
    IAmbireAccount _acct = _buildAccount(_AMBIRE_IMPLEMENTATION);
    assertEq(address(_acct).code, ActionAmbireProxy.runtime(_AMBIRE_IMPLEMENTATION), 'the proxy shape');
    assertEq(_acct.privileges(_signer), _SIGNER_VALUE, 'the one privileged address the creation code writes');
    assertEq(_acct.privileges(makeAddr('stranger')), bytes32(0));
    assertTrue(_action.supportsAccount(address(_acct)), 'fit check');
    assertTrue(_action.isAuthority(address(_acct), _signer), 'the signer key is a key');
    assertTrue(_action.holdsAnyPrivilege(address(_acct), _signer));
    assertFalse(_action.isAuthorized(address(_acct)), 'does not authorize the action yet');

    string memory _kit = 'kit';
    address _kitSlot = address(uint160(uint256(keccak256(abi.encode(_kit, address(_action))))));
    _selfWrite(_acct, _kitSlot, keccak256(abi.encode(address(_action), bytes(''))));
    assertTrue(_action.isAuthorized(address(_acct)), 'authorizes the action through setAddrPrivilege');
    assertFalse(_action.isAuthority(address(_acct), _kitSlot));
    _selfWrite(_acct, _kitSlot, bytes32(0));
    assertFalse(_action.isAuthorized(address(_acct)), 'no longer authorizes the action');
  }

  /// @notice A mainnet account built by the factory is supported, privileges its one signer key at
  ///         2, and starts and stops authorizing the action through setAddrPrivilege as the views report.
  function test_WhenAMainnetAccountIsBuiltByThePinnedFactory() external {
    _fork('MAINNET_RPC_URL', _MAINNET_BLOCK);
    // it should be supported and privilege only its signer key
    _checkBuiltAccount();
  }

  /// @notice The same account checks on Sepolia.
  function test_WhenASepoliaAccountIsBuiltByThePinnedFactory() external {
    _fork('SEPOLIA_RPC_URL', _SEPOLIA_BLOCK);
    // it should be supported and privilege only its signer key
    _checkBuiltAccount();
  }

  /*///////////////////////////////////////////////////////////////
                     FAILING CALL REVERT DATA
  ///////////////////////////////////////////////////////////////*/

  function _checkFailingCall() internal {
    IAmbireAccount _acct = _buildAccount(_AMBIRE_IMPLEMENTATION);
    ActionForkApprovingValidator _validator = new ActionForkApprovingValidator();
    ActionForkRefusingTarget _refusing = new ActionForkRefusingTarget();
    ActionForkCountingTarget _counting = new ActionForkCountingTarget();
    address _slot = address(uint160(uint256(keccak256('action.fork.validatorSlot'))));
    _selfWrite(_acct, _slot, keccak256(abi.encode(address(_validator), bytes(''))));

    IAmbireRecoveryAction.Transaction[] memory _calls = new IAmbireRecoveryAction.Transaction[](2);
    _calls[0] = IAmbireRecoveryAction.Transaction({
      to: address(_counting), value: 0, data: abi.encodeCall(ActionForkCountingTarget.bump, ())
    });
    bytes memory _refuseCall = abi.encodeCall(ActionForkRefusingTarget.refuse, ());
    _calls[1] = IAmbireRecoveryAction.Transaction({to: address(_refusing), value: 0, data: _refuseCall});
    bytes memory _validatorData = abi.encode(_slot, address(_validator), bytes(''), bytes(''));
    bytes memory _signature = abi.encodePacked(_validatorData, uint8(255));

    vm.expectRevert(
      abi.encodeWithSelector(ActionForkRefusingTarget.ActionForkRefusingTarget_Refused.selector, uint256(42), 'inner')
    );
    _acct.execute(_calls, _signature);
    assertEq(_counting.count(), 0, 'all or nothing');

    _calls[1] = IAmbireRecoveryAction.Transaction({
      to: address(_counting), value: 0, data: abi.encodeCall(ActionForkCountingTarget.bump, ())
    });
    _acct.execute(_calls, _signature);
    assertEq(_counting.count(), 2, 'the same route runs a batch that does not fail');
  }

  /// @notice On mainnet a failing call inside execute reverts the whole batch with that call's own
  ///         revert data, so the SDK decodes the real error and no earlier call runs.
  function test_WhenAMainnetBatchCallFails() external {
    _fork('MAINNET_RPC_URL', _MAINNET_BLOCK);
    // it should revert execute with the call's own revert data
    _checkFailingCall();
  }

  /// @notice The same revert behavior on Sepolia.
  function test_WhenASepoliaBatchCallFails() external {
    _fork('SEPOLIA_RPC_URL', _SEPOLIA_BLOCK);
    // it should revert execute with the call's own revert data
    _checkFailingCall();
  }

  /*///////////////////////////////////////////////////////////////
                          PRIVILEGE EVENT
  ///////////////////////////////////////////////////////////////*/

  function _checkPrivilegeEvent() internal {
    IAmbireAccount _acct = _buildAccount(_AMBIRE_IMPLEMENTATION);
    address _written = makeAddr('writtenKey');
    bytes32 _value = bytes32(uint256(1));
    vm.recordLogs();
    _selfWrite(_acct, _written, _value);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    uint256 _found;
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].emitter != address(_acct)) continue;
      assertEq(_logs[_i].topics.length, 2, 'one indexed argument');
      assertEq(_logs[_i].topics[0], keccak256('LogPrivilegeChanged(address,bytes32)'), 'Ambire event signature');
      assertEq(_logs[_i].topics[0], IAmbireAccount.LogPrivilegeChanged.selector, 'the local ABI event topic');
      assertEq(_logs[_i].topics[1], bytes32(uint256(uint160(_written))));
      assertEq(_logs[_i].data, abi.encode(_value));
      ++_found;
    }
    assertEq(_found, 1, 'one event per write');
    assertEq(_acct.privileges(_written), _value);
  }

  /// @notice On mainnet one privilege write emits one LogPrivilegeChanged with the address indexed and
  ///         the value as data, the layout the SDK's alerting reads.
  function test_WhenAMainnetPrivilegeIsWritten() external {
    _fork('MAINNET_RPC_URL', _MAINNET_BLOCK);
    // it should emit Ambire's event layout
    _checkPrivilegeEvent();
  }

  /// @notice The same event layout on Sepolia.
  function test_WhenASepoliaPrivilegeIsWritten() external {
    _fork('SEPOLIA_RPC_URL', _SEPOLIA_BLOCK);
    // it should emit Ambire's event layout
    _checkPrivilegeEvent();
  }
  /*///////////////////////////////////////////////////////////////
                          FALLBACK HANDLER
  ///////////////////////////////////////////////////////////////*/

  function _checkFreshFallback() internal {
    IAmbireAccount _acct = _buildAccount(_AMBIRE_IMPLEMENTATION);
    assertEq(_acct.privileges(_FALLBACK_HANDLER_SLOT), bytes32(0), 'a fresh account names no handler');
    vm.prank(makeAddr('anyCaller'));
    (bool _ok, bytes memory _returned) =
      address(_acct).call(abi.encodeCall(ActionForkFallbackHandler.mark, (bytes32(uint256(7)))));
    assertTrue(_ok, 'the unknown call succeeds');
    assertEq(_returned.length, 0, 'the unknown call returns nothing');
    assertEq(vm.load(address(_acct), keccak256('action.fork.fallbackHandler.mark')), bytes32(0), 'nothing ran');
  }

  /// @notice On mainnet a fresh account answers a call with an unknown selector with success and no data,
  ///         which is why the fit check cannot tell accounts apart by probing them.
  function test_WhenAMainnetFreshAccountGetsAnUnknownSelector() external {
    _fork('MAINNET_RPC_URL', _MAINNET_BLOCK);
    // it should succeed and return nothing
    _checkFreshFallback();
  }

  /// @notice The same fresh-account answer on Sepolia.
  function test_WhenASepoliaFreshAccountGetsAnUnknownSelector() external {
    _fork('SEPOLIA_RPC_URL', _SEPOLIA_BLOCK);
    // it should succeed and return nothing
    _checkFreshFallback();
  }

  function _checkInstalledFallback() internal {
    IAmbireAccount _acct = _buildAccount(_AMBIRE_IMPLEMENTATION);
    ActionForkFallbackHandler _handler = new ActionForkFallbackHandler();
    _selfWrite(_acct, _FALLBACK_HANDLER_SLOT, bytes32(uint256(uint160(address(_handler)))));
    bytes32 _value = keccak256('action.fork.fallbackHandler.value');

    vm.prank(makeAddr('anyCaller'));
    (bool _ok, bytes memory _returned) = address(_acct).call(abi.encodeCall(ActionForkFallbackHandler.mark, (_value)));
    assertTrue(_ok, 'the handled call succeeds');
    assertEq(abi.decode(_returned, (address)), address(_acct), 'the handler ran as the account');
    assertEq(vm.load(address(_acct), _handler.MARK_SLOT()), _value, 'the handler wrote the account storage');
    assertEq(vm.load(address(_handler), _handler.MARK_SLOT()), bytes32(0), 'the handler storage is untouched');
  }

  /// @notice On mainnet, once the account names a handler under 0x6969, any caller's unknown selector runs
  ///         that handler in the account's own storage. Such a handler survives a handover, so it is account
  ///         authority the holder must recognize.
  function test_WhenAMainnetAccountNamesAFallbackHandler() external {
    _fork('MAINNET_RPC_URL', _MAINNET_BLOCK);
    // it should run the handler in the account's storage
    _checkInstalledFallback();
  }

  /// @notice The same handler behavior on Sepolia.
  function test_WhenASepoliaAccountNamesAFallbackHandler() external {
    _fork('SEPOLIA_RPC_URL', _SEPOLIA_BLOCK);
    // it should run the handler in the account's storage
    _checkInstalledFallback();
  }

  function _checkMaskedFallback() internal {
    IAmbireAccount _acct = _buildAccount(_AMBIRE_IMPLEMENTATION);
    ActionForkFallbackHandler _handler = new ActionForkFallbackHandler();
    _selfWrite(_acct, _FALLBACK_HANDLER_SLOT, bytes32(uint256(1) << 200));

    vm.prank(makeAddr('anyCaller'));
    (bool _ok, bytes memory _returned) =
      address(_acct).call(abi.encodeCall(ActionForkFallbackHandler.mark, (keccak256('action.fork.masked'))));
    assertTrue(_ok, 'the unknown call succeeds');
    assertEq(_returned.length, 0, 'the unknown call returns nothing');
    assertEq(vm.load(address(_acct), _handler.MARK_SLOT()), bytes32(0), 'nothing ran');
  }

  /// @notice On mainnet an entry under 0x6969 whose low twenty bytes are zero names no handler, whatever its upper
  ///         bytes hold, so an unknown call still succeeds with no data. The local stand-ins read the entry the same
  ///         way.
  function test_WhenAMainnetHandlerEntryHoldsOnlyUpperBytes() external {
    _fork('MAINNET_RPC_URL', _MAINNET_BLOCK);
    // it should succeed and return nothing
    _checkMaskedFallback();
  }

  /// @notice The same masked entry on Sepolia.
  function test_WhenASepoliaHandlerEntryHoldsOnlyUpperBytes() external {
    _fork('SEPOLIA_RPC_URL', _SEPOLIA_BLOCK);
    // it should succeed and return nothing
    _checkMaskedFallback();
  }
}
