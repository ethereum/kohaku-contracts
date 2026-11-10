// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Vm} from 'forge-std/Vm.sol';
import {IPolicyMethodAdmin} from 'interfaces/IPolicyMethodAdmin.sol';
import {IPolicyMethodPause} from 'interfaces/IPolicyMethodPause.sol';
import {MethodRolesHarness} from 'test/mocks/MethodRolesHarness.sol';
import {MethodRolesTestBase} from 'test/utils/MethodRolesTestBase.sol';

/// @notice The roles base emits exactly the six events that IPolicyMethodPause and IPolicyMethodAdmin
///         declare. Watchers decode these layouts.
contract PolicyMethodRolesEventsTest is MethodRolesTestBase {
  /// @notice Deployment emits exactly three events. OpenZeppelin's OwnershipTransferred names the initial
  ///         pause holder, AdminTransferred names the initial key admin and TrustedKeysUpdated carries the
  ///         initial keys. A watcher that replays these events sees who held each role from the first block.
  function test_WhenTheMethodIsDeployed() external {
    vm.recordLogs();
    MethodRolesHarness _deployed = _deploy(_pauseHolder, _keyAdmin, _initialKeys);
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    bytes32[3] memory _expected = [
      Ownable.OwnershipTransferred.selector,
      IPolicyMethodAdmin.AdminTransferred.selector,
      IPolicyMethodAdmin.TrustedKeysUpdated.selector
    ];
    bool[3] memory _seen;
    // it should emit only OwnershipTransferred, AdminTransferred and TrustedKeysUpdated, once each.
    assertEq(_logs.length, _expected.length, 'event count at deployment');
    for (uint256 _i = 0; _i < _logs.length; _i++) {
      assertEq(_logs[_i].emitter, address(_deployed), 'emitter');
      bool _known;
      for (uint256 _j = 0; _j < _expected.length; _j++) {
        if (_logs[_i].topics[0] == _expected[_j]) {
          assertFalse(_seen[_j], 'event emitted twice');
          _seen[_j] = true;
          _known = true;
        }
      }
      assertTrue(_known, 'unexpected event at deployment');
    }
  }

  /// @notice One pass through the key admin and stop functions emits only the six role events, and each of
  ///         them at least once. Watchers decode exactly these layouts, so an unknown event goes unseen.
  function test_WhenEveryKeyAdminAndStopFunctionRunsOnce() external {
    bytes32[6] memory _declared = _declaredEvents();
    bool[6] memory _seen;

    vm.recordLogs();
    vm.prank(_pauseHolder);
    _roles.pause();
    vm.prank(_pauseHolder);
    _roles.unpause();
    vm.prank(_keyAdmin);
    _roles.setTrustedKeys(_keyList(keccak256('k')));
    vm.prank(_keyAdmin);
    _roles.transferAdmin(_nominee);
    vm.prank(_nominee);
    _roles.acceptAdmin();
    vm.prank(_nominee);
    _roles.renounceAdmin();
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    assertGt(_logs.length, 0, 'no logs');
    for (uint256 _i = 0; _i < _logs.length; _i++) {
      // it should emit each of the six events from the method.
      assertEq(_logs[_i].emitter, address(_roles), 'emitter');
      bool _known;
      for (uint256 _j = 0; _j < _declared.length; _j++) {
        if (_logs[_i].topics[0] == _declared[_j]) {
          _known = true;
          _seen[_j] = true;
        }
      }
      // it should emit only the six events the interfaces declare.
      assertTrue(_known, 'undeclared event');
    }
    for (uint256 _j = 0; _j < _declared.length; _j++) {
      assertTrue(_seen[_j], 'declared event not emitted');
    }
  }

  /// @notice Offering the pause holder role emits OwnershipTransferStarted with the current holder and the
  ///         nominee. A watcher sees the stop changing hands before the nominee can use it.
  function test_WhenThePauseHolderOffersTheRole() external {
    // it should emit OwnershipTransferStarted with the holder and the nominee.
    vm.expectEmit(true, true, true, true, address(_roles));
    emit Ownable2Step.OwnershipTransferStarted(_pauseHolder, _nominee);
    vm.prank(_pauseHolder);
    _roles.transferOwnership(_nominee);
  }

  /// @notice Accepting the pause holder role emits OwnershipTransferred with the former holder and the
  ///         nominee. A watcher learns who can stop recoveries on this method from that block on.
  function test_WhenTheNomineeAcceptsThePauseHolderRole() external {
    vm.prank(_pauseHolder);
    _roles.transferOwnership(_nominee);
    // it should emit OwnershipTransferred with the former holder and the nominee.
    vm.expectEmit(true, true, true, true, address(_roles));
    emit Ownable.OwnershipTransferred(_pauseHolder, _nominee);
    vm.prank(_nominee);
    _roles.acceptOwnership();
  }

  /// @notice Renouncing the pause holder role emits OwnershipTransferred with the former holder and the zero
  ///         address. A watcher learns that nobody can stop or resume this method any more.
  function test_WhenThePauseHolderRenouncesTheRole() external {
    // it should emit OwnershipTransferred with the former holder and the zero address.
    vm.expectEmit(true, true, true, true, address(_roles));
    emit Ownable.OwnershipTransferred(_pauseHolder, address(0));
    vm.prank(_pauseHolder);
    _roles.renounceOwnership();
  }

  /// @dev The topics of the six events the two role interfaces declare, the only ones a watcher decodes.
  function _declaredEvents() internal pure returns (bytes32[6] memory _events) {
    _events = [
      IPolicyMethodAdmin.TrustedKeysUpdated.selector,
      IPolicyMethodAdmin.AdminTransferOffered.selector,
      IPolicyMethodAdmin.AdminTransferred.selector,
      IPolicyMethodAdmin.AdminRenounced.selector,
      IPolicyMethodPause.Paused.selector,
      IPolicyMethodPause.Unpaused.selector
    ];
  }
}
