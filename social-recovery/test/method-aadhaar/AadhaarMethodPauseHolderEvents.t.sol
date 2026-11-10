// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {MethodAadhaarTestBase} from 'test/utils/MethodAadhaarTestBase.sol';

/// @notice Every change of the Aadhaar method's pause holder emits its event, so a watcher can follow who
///         is able to stop recoveries that use this method.
contract AadhaarMethodPauseHolderEventsTest is MethodAadhaarTestBase {
  address internal _pauseNominee = makeAddr('pauseNominee');

  /// @notice Offering the pause holder role emits OwnershipTransferStarted with the current holder and the
  ///         nominee. A watcher sees the stop changing hands before the nominee can use it.
  function test_WhenThePauseHolderOffersTheRole() external {
    // it should emit OwnershipTransferStarted with the holder and the nominee
    vm.expectEmit(true, true, true, true, address(_method));
    emit Ownable2Step.OwnershipTransferStarted(_owner, _pauseNominee);
    vm.prank(_owner);
    _method.transferOwnership(_pauseNominee);
  }

  /// @notice Accepting the pause holder role emits OwnershipTransferred with the former holder and the
  ///         nominee. A watcher learns who can stop recoveries on this method from that block on.
  function test_WhenTheNomineeAcceptsThePauseHolderRole() external {
    vm.prank(_owner);
    _method.transferOwnership(_pauseNominee);
    // it should emit OwnershipTransferred with the former holder and the nominee
    vm.expectEmit(true, true, true, true, address(_method));
    emit Ownable.OwnershipTransferred(_owner, _pauseNominee);
    vm.prank(_pauseNominee);
    _method.acceptOwnership();
  }

  /// @notice Renouncing the pause holder role emits OwnershipTransferred with the former holder and the zero
  ///         address. A watcher learns that nobody can stop or resume this method any more.
  function test_WhenThePauseHolderRenouncesTheRole() external {
    // it should emit OwnershipTransferred with the former holder and the zero address
    vm.expectEmit(true, true, true, true, address(_method));
    emit Ownable.OwnershipTransferred(_owner, address(0));
    vm.prank(_owner);
    _method.renounceOwnership();
  }
}
