// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {ActionAmbireAccountFixture} from 'test/mocks/ActionAmbireAccountFixture.sol';
import {ActionForkFallbackHandler} from 'test/utils/ActionAmbireForkAbi.sol';

/// @notice The action tests' stand-in for Ambire's account must treat its 0x6969 entry as the deployed
///         implementation does, which keeps only the entry's low twenty bytes as the handler's address. A stand-in
///         that read the whole word would run, or skip, a handler the deployed account would not, and the action's
///         tests would describe another account.
contract ActionAmbireAccountFixtureFallbackTest is Test {
  /// @notice The privilege key whose entry names the fallback handler.
  address internal constant _HANDLER_SLOT = address(0x6969);

  ActionAmbireAccountFixture internal _account;
  ActionForkFallbackHandler internal _handler;

  function setUp() public {
    _account = new ActionAmbireAccountFixture();
    _handler = new ActionForkFallbackHandler();
  }

  /// @dev The account writes `_entry` under 0x6969 itself, the only caller it lets write its privileges.
  function _setEntry(bytes32 _entry) internal {
    vm.prank(address(_account));
    _account.setAddrPrivilege(_HANDLER_SLOT, _entry);
  }

  /// @dev Anyone calls the handler's selector, which the account does not know.
  function _callUnknown(bytes32 _value) internal returns (bool _ok, bytes memory _returned) {
    vm.prank(makeAddr('anyone'));
    (_ok, _returned) = address(_account).call(abi.encodeCall(ActionForkFallbackHandler.mark, (_value)));
  }

  /// @notice An entry whose low twenty bytes are zero names no handler, whatever its upper bytes hold, so an unknown
  ///         call is accepted, returns nothing and writes nothing. `_upperSeed` picks the upper twelve bytes, bounded
  ///         so at least one bit is set.
  function test_WhenTheEntryHoldsOnlyUpperBytes(uint256 _upperSeed) external {
    _setEntry(bytes32(bound(_upperSeed, 1, type(uint96).max) << 160));
    (bool _ok, bytes memory _returned) = _callUnknown(keccak256('value'));
    // it should accept the call and return nothing
    assertTrue(_ok, 'the unknown call is accepted');
    assertEq(_returned.length, 0, 'the unknown call returns nothing');
    // it should run no handler
    assertEq(vm.load(address(_account), _handler.MARK_SLOT()), bytes32(0), 'no handler ran');
  }

  /// @notice An entry whose low twenty bytes name the handler runs it in the account's storage even when the upper
  ///         bytes are set, since only the low twenty bytes are read. `_upperSeed` picks the upper twelve bytes,
  ///         bounded so at least one bit is set.
  function test_WhenTheEntryHoldsUpperBytesAndAHandler(uint256 _upperSeed) external {
    _setEntry(bytes32((bound(_upperSeed, 1, type(uint96).max) << 160) | uint256(uint160(address(_handler)))));
    bytes32 _value = keccak256('value');
    (bool _ok, bytes memory _returned) = _callUnknown(_value);
    // it should run the handler in the account's storage
    assertTrue(_ok, 'the handled call succeeds');
    assertEq(abi.decode(_returned, (address)), address(_account), 'the handler ran as the account');
    assertEq(vm.load(address(_account), _handler.MARK_SLOT()), _value, 'the handler wrote the account storage');
  }
}
