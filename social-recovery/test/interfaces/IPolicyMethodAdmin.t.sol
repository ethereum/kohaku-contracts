// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Vm} from 'forge-std/Vm.sol';
import {IPolicyMethodAdmin} from 'interfaces/IPolicyMethodAdmin.sol';
import {InterfacesArtifacts} from 'test/utils/InterfacesArtifacts.sol';

/// @notice Checks the call surface of IPolicyMethodAdmin: its selectors, its events' topics, indexing and data
///         order, and each declaration in the compiled ABI.
contract IPolicyMethodAdminTest is InterfacesArtifacts {
  /// Checks each selector of IPolicyMethodAdmin is the first four bytes of keccak256 of the function's
  /// canonical signature. Every caller encodes calls from that signature, so a drift breaks the call.
  function test_WhenTheSelectorsAreDerived() external pure {
    // it should match each function's canonical signature
    _interfacesAssertSelector(IPolicyMethodAdmin.setTrustedKeys.selector, 'setTrustedKeys(bytes32[])');
    _interfacesAssertSelector(IPolicyMethodAdmin.transferAdmin.selector, 'transferAdmin(address)');
    _interfacesAssertSelector(IPolicyMethodAdmin.acceptAdmin.selector, 'acceptAdmin()');
    _interfacesAssertSelector(IPolicyMethodAdmin.pendingAdmin.selector, 'pendingAdmin()');
    _interfacesAssertSelector(IPolicyMethodAdmin.renounceAdmin.selector, 'renounceAdmin()');
  }

  /// Checks the selectors of the two errors the roles contract raises, PolicyMethodRoles_AdminUnauthorizedAccount
  /// and PolicyMethodRoles_AdminInvalidAdmin, are the first four bytes of keccak256 of their signatures. Clients
  /// decode a refused admin call by this selector, so a drift turns a named error into an unknown revert.
  function test_WhenTheErrorSelectorsAreDerived() external pure {
    // it should match each error's canonical signature
    _interfacesAssertSelector(
      IPolicyMethodAdmin.PolicyMethodRoles_AdminUnauthorizedAccount.selector,
      'PolicyMethodRoles_AdminUnauthorizedAccount(address)'
    );
    _interfacesAssertSelector(
      IPolicyMethodAdmin.PolicyMethodRoles_AdminInvalidAdmin.selector, 'PolicyMethodRoles_AdminInvalidAdmin(address)'
    );
  }

  /// Emits TrustedKeysUpdated with distinct sample values and checks which parameters become log topics and
  /// the order of the rest in the log data. A watcher that follows a recovery decodes the log this way.
  function test_WhenTrustedKeysUpdatedIsEmitted() external {
    // it should index and order its fields as specified
    bytes32[] memory _previous = new bytes32[](1);
    _previous[0] = bytes32(uint256(0xb002));
    bytes32[] memory _current = new bytes32[](1);
    _current[0] = bytes32(uint256(0xb004));
    vm.recordLogs();
    emit IPolicyMethodAdmin.TrustedKeysUpdated(_previous, _current);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics.length, 1, 'topics');
    assertEq(_logs[0].topics[0], keccak256(bytes('TrustedKeysUpdated(bytes32[],bytes32[])')), 'topic0');
    assertEq(_logs[0].data, abi.encode(_previous, _current), 'data');
  }

  /// Emits AdminTransferOffered with distinct sample values and checks which parameters become log topics and
  /// the order of the rest in the log data. A watcher that follows a recovery decodes the log this way.
  function test_WhenAdminTransferOfferedIsEmitted() external {
    // it should index and order its fields as specified
    address _current = address(0x1001);
    address _pending = address(0x1002);
    vm.recordLogs();
    emit IPolicyMethodAdmin.AdminTransferOffered(_current, _pending);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics.length, 3, 'topics');
    assertEq(_logs[0].topics[0], keccak256(bytes('AdminTransferOffered(address,address)')), 'topic0');
    assertEq(_logs[0].topics[1], bytes32(uint256(uint160(_current))), 'current');
    assertEq(_logs[0].topics[2], bytes32(uint256(uint160(_pending))), 'pending');
    assertEq(_logs[0].data, abi.encode(), 'data');
  }

  /// Emits AdminTransferred with distinct sample values and checks which parameters become log topics and
  /// the order of the rest in the log data. A watcher that follows a recovery decodes the log this way.
  function test_WhenAdminTransferredIsEmitted() external {
    // it should index and order its fields as specified
    address _previous = address(0x1001);
    address _current = address(0x1002);
    vm.recordLogs();
    emit IPolicyMethodAdmin.AdminTransferred(_previous, _current);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics.length, 3, 'topics');
    assertEq(_logs[0].topics[0], keccak256(bytes('AdminTransferred(address,address)')), 'topic0');
    assertEq(_logs[0].topics[1], bytes32(uint256(uint160(_previous))), 'previous');
    assertEq(_logs[0].topics[2], bytes32(uint256(uint160(_current))), 'current');
    assertEq(_logs[0].data, abi.encode(), 'data');
  }

  /// Emits AdminRenounced with distinct sample values and checks which parameters become log topics and
  /// the order of the rest in the log data. A watcher that follows a recovery decodes the log this way.
  function test_WhenAdminRenouncedIsEmitted() external {
    // it should index and order its fields as specified
    address _previous = address(0x1001);
    vm.recordLogs();
    emit IPolicyMethodAdmin.AdminRenounced(_previous);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics.length, 2, 'topics');
    assertEq(_logs[0].topics[0], keccak256(bytes('AdminRenounced(address)')), 'topic0');
    assertEq(_logs[0].topics[1], bytes32(uint256(uint160(_previous))), 'previous');
    assertEq(_logs[0].data, abi.encode(), 'data');
  }

  /// Reads the compiled ABI of IPolicyMethodAdmin and checks it lists exactly the specified functions, events
  /// and errors. An extra or missing entry changes the surface every other contract compiles against.
  function test_WhenTheCompiledAbiIsRead() external {
    // it should list exactly the specified functions events and errors
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    string[] memory _signatures = new string[](5);
    _signatures[0] = 'setTrustedKeys(bytes32[])';
    _signatures[1] = 'transferAdmin(address)';
    _signatures[2] = 'acceptAdmin()';
    _signatures[3] = 'pendingAdmin()';
    _signatures[4] = 'renounceAdmin()';
    _interfacesAssertMethodIdentifiers(_json, _signatures);
    assertEq(_interfacesAbiCount(_json, 'function'), 5, 'functions');
    assertEq(_interfacesAbiCount(_json, 'event'), 4, 'events');
    assertEq(_interfacesAbiCount(_json, 'error'), 2, 'errors');
  }

  /// Checks that setTrustedKeys in the compiled ABI of IPolicyMethodAdmin has the specified parameter and return types
  /// and names and is nonpayable. Clients encode their calls from these types and names.
  function test_WhenSetTrustedKeysIsReadFromTheAbi() external {
    // it should declare the specified parameters returns and mutability
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertFunction(_json, 'setTrustedKeys', 'nonpayable', 'bytes32[] _trustedKeys', '');
  }

  /// Checks that transferAdmin in the compiled ABI of IPolicyMethodAdmin has the specified parameter and return types
  /// and names and is nonpayable. Clients encode their calls from these types and names.
  function test_WhenTransferAdminIsReadFromTheAbi() external {
    // it should declare the specified parameters returns and mutability
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertFunction(_json, 'transferAdmin', 'nonpayable', 'address _newAdmin', '');
  }

  /// Checks that acceptAdmin in the compiled ABI of IPolicyMethodAdmin has the specified parameter and return types
  /// and names and is nonpayable. Clients encode their calls from these types and names.
  function test_WhenAcceptAdminIsReadFromTheAbi() external {
    // it should declare the specified parameters returns and mutability
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertFunction(_json, 'acceptAdmin', 'nonpayable', '', '');
  }

  /// Checks that pendingAdmin in the compiled ABI of IPolicyMethodAdmin has the specified parameter and return types
  /// and names and is view. A view is what lets a caller reach it with a static call, which can write nothing.
  function test_WhenPendingAdminIsReadFromTheAbi() external {
    // it should declare the specified parameters returns and mutability
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertFunction(_json, 'pendingAdmin', 'view', '', 'address _pendingAdmin');
  }

  /// Checks that renounceAdmin in the compiled ABI of IPolicyMethodAdmin has the specified parameter and return types
  /// and names and is nonpayable. Clients encode their calls from these types and names.
  function test_WhenRenounceAdminIsReadFromTheAbi() external {
    // it should declare the specified parameters returns and mutability
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertFunction(_json, 'renounceAdmin', 'nonpayable', '', '');
  }

  /// Checks that the event TrustedKeysUpdated in the compiled ABI has the specified parameter types, names
  /// and indexed flags and is not anonymous. Watchers decode the log from exactly this layout.
  function test_WhenTheEventTrustedKeysUpdatedIsReadFromTheAbi() external {
    // it should declare the specified parameters
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertEvent(_json, 'TrustedKeysUpdated', 'bytes32[] _previous,bytes32[] _current');
  }

  /// Checks that the event AdminTransferOffered in the compiled ABI has the specified parameter types, names
  /// and indexed flags and is not anonymous. Watchers decode the log from exactly this layout.
  function test_WhenTheEventAdminTransferOfferedIsReadFromTheAbi() external {
    // it should declare the specified parameters
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertEvent(_json, 'AdminTransferOffered', 'address indexed _current,address indexed _pending');
  }

  /// Checks that the event AdminTransferred in the compiled ABI has the specified parameter types, names
  /// and indexed flags and is not anonymous. Watchers decode the log from exactly this layout.
  function test_WhenTheEventAdminTransferredIsReadFromTheAbi() external {
    // it should declare the specified parameters
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertEvent(_json, 'AdminTransferred', 'address indexed _previous,address indexed _current');
  }

  /// Checks that the event AdminRenounced in the compiled ABI has the specified parameter types, names
  /// and indexed flags and is not anonymous. Watchers decode the log from exactly this layout.
  function test_WhenTheEventAdminRenouncedIsReadFromTheAbi() external {
    // it should declare the specified parameters
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertEvent(_json, 'AdminRenounced', 'address indexed _previous');
  }

  /// Checks the parameter types and names of the two errors in the compiled ABI of IPolicyMethodAdmin: the refused
  /// caller and the refused admin. A client shows the refused address by this name, so a renamed parameter
  /// mislabels it.
  function test_WhenTheErrorsAreReadFromTheAbi() external {
    // it should declare each with the specified parameters
    string memory _json = _interfacesLoad('IPolicyMethodAdmin');
    _interfacesAssertError(_json, 'PolicyMethodRoles_AdminUnauthorizedAccount', 'address _account');
    _interfacesAssertError(_json, 'PolicyMethodRoles_AdminInvalidAdmin', 'address _admin');
  }
}
