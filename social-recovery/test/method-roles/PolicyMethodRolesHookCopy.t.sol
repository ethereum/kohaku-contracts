// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test, Vm} from 'forge-std/Test.sol';
import {IPolicyMethodAdmin} from 'interfaces/IPolicyMethodAdmin.sol';
import {MethodRolesScribblingHarness} from 'test/mocks/MethodRolesScribblingHarness.sol';

/// @notice The roles base hands its key validation hook an independent copy of the list, so a hook that writes its
///         argument cannot change the keys the method stores and reports. A method's hook is the method author's
///         code, and the keys a holder sees at adoption must be the ones the key admin set, not ones a hook rewrote.
contract PolicyMethodRolesHookCopyTest is Test {
  address internal _pauseHolder = makeAddr('pauseHolder');
  address internal _keyAdmin = makeAddr('keyAdmin');

  /// @dev A list of two words.
  function _list(bytes32 _a, bytes32 _b) internal pure returns (bytes32[] memory _keys) {
    _keys = new bytes32[](2);
    (_keys[0], _keys[1]) = (_a, _b);
  }

  /// @dev Asserts two key lists hold the same words in the same order.
  function _assertKeys(bytes32[] memory _actual, bytes32[] memory _expected) internal pure {
    assertEq(_actual.length, _expected.length, 'keys length');
    for (uint256 _i; _i < _expected.length; ++_i) {
      assertEq(_actual[_i], _expected[_i], 'key word');
    }
  }

  /// @dev The `_current` list of the one TrustedKeysUpdated log `_emitter` wrote among `_logs`.
  function _currentKeys(Vm.Log[] memory _logs, address _emitter) internal pure returns (bytes32[] memory _current) {
    uint256 _found;
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].emitter != _emitter || _logs[_i].topics[0] != IPolicyMethodAdmin.TrustedKeysUpdated.selector) {
        continue;
      }
      (, _current) = abi.decode(_logs[_i].data, (bytes32[], bytes32[]));
      ++_found;
    }
    assertEq(_found, 1, 'one TrustedKeysUpdated');
  }

  /// @notice A method deployed with a hook that overwrites its argument still stores and reports the constructor's
  ///         own list, and its deployment event carries that list, so the first keys a watcher and a holder see are
  ///         the ones the deployer gave.
  function test_WhenTheHookWritesTheInitialList() external {
    bytes32[] memory _initial = _list(keccak256('initial.0'), keccak256('initial.1'));
    vm.recordLogs();
    MethodRolesScribblingHarness _method =
      new MethodRolesScribblingHarness(_pauseHolder, _keyAdmin, _initial, 'Scribbling Method', '1.0.0');
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    bytes32[] memory _expected = _list(keccak256('initial.0'), keccak256('initial.1'));

    (,, bytes32[] memory _stored,,) = _method.trustedParties();
    // it should report the constructor's own list unchanged
    _assertKeys(_stored, _expected);
    // it should emit TrustedKeysUpdated carrying that list
    _assertKeys(_currentKeys(_logs, address(_method)), _expected);
  }

  /// @notice A key admin's new list goes through the same hook. The method still stores and reports the list the
  ///         admin sent, and the event carries that list, so a hook cannot swap the keys of a rotation.
  function test_WhenTheHookWritesASetList() external {
    MethodRolesScribblingHarness _method = new MethodRolesScribblingHarness(
      _pauseHolder, _keyAdmin, _list(keccak256('initial.0'), keccak256('initial.1')), 'Scribbling Method', '1.0.0'
    );
    bytes32[] memory _next = _list(keccak256('next.0'), keccak256('next.1'));
    vm.recordLogs();
    vm.prank(_keyAdmin);
    _method.setTrustedKeys(_next);
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    (,, bytes32[] memory _stored,,) = _method.trustedParties();
    // it should report the admin's list unchanged
    _assertKeys(_stored, _next);
    // it should emit TrustedKeysUpdated carrying that list
    _assertKeys(_currentKeys(_logs, address(_method)), _next);
  }
}
