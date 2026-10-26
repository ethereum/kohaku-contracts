// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BasePrivacyPaymaster} from "../../contracts/BasePrivacyPaymaster.sol";
import {IPrivacyPool} from "../../contracts/privacypools/interfaces/IPrivacyPool.sol";

/// Paymaster whose `_collectFee` returns configurable values without
/// touching any protocol.
contract MockPaymaster is BasePrivacyPaymaster {
    uint256 internal feePaid;
    address internal refundRecipient;

    constructor(IEntryPoint _entryPoint) BasePrivacyPaymaster(_entryPoint) {}

    function setFee(uint256 _feePaid, address _refundRecipient) external {
        feePaid = _feePaid;
        refundRecipient = _refundRecipient;
    }

    function _collectFee(PackedUserOperation calldata) internal view override returns (uint256, address) {
        return (feePaid, refundRecipient);
    }

    function test() public {}
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function test() public {}
}

contract RejectEther {
    receive() external payable {
        revert("no");
    }

    function test() public {}
}

/// Minimal account that accepts every op and burns a configurable amount of gas.
contract GasBurnerAccount is IAccount {
    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    function burn(uint256 gasToBurn) external view {
        uint256 target = gasleft() - gasToBurn;
        while (gasleft() > target) {}
    }

    function test() public {}
}

/// Mock of a privacy-pools-core pool. Pushes `pubSignals[2]` (the
/// withdrawn value) to the withdrawal's processooor, mimicking the real
/// pool's `_push`. No Groth16 verification is performed.
contract MockPrivacyPool is IPrivacyPool {
    using SafeERC20 for IERC20;

    address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    error MockRevert();

    address internal _asset;
    bool internal shouldFail;

    constructor(address _asset_) {
        _asset = _asset_;
    }

    function ASSET() external view override returns (address) {
        return _asset;
    }

    function SCOPE() external pure override returns (uint256) {
        return 0;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function withdraw(IPrivacyPool.Withdrawal memory _withdrawal, IPrivacyPool.WithdrawProof memory _proof)
        external
        override
    {
        if (msg.sender != _withdrawal.processooor) revert MockRevert();
        if (shouldFail) revert MockRevert();

        uint256 value = _proof.pubSignals[2];
        if (_asset == NATIVE_ASSET) {
            (bool ok,) = payable(_withdrawal.processooor).call{value: value}("");
            require(ok);
        } else {
            IERC20(_asset).safeTransfer(_withdrawal.processooor, value);
        }
    }

    function test() public {}
}

/// Mock of an ETH Tornado instance. Pays `fee` to the relayer and the rest
/// of the denomination to the recipient. No proof verification is performed.
contract MockEthTornado {
    uint256 public constant denomination = 1 ether;

    address public lastRelayer;

    function withdraw(
        bytes calldata,
        bytes32,
        bytes32,
        address payable recipient,
        address payable relayer,
        uint256 fee,
        uint256 refund
    ) external payable {
        require(msg.value == 0 && refund == 0, "refund");
        lastRelayer = relayer;

        (bool ok,) = recipient.call{value: denomination - fee}("");
        require(ok);
        (ok,) = relayer.call{value: fee}("");
        require(ok);
    }

    function test() public {}
}

/// Mock of an ERC20 Tornado instance, which exposes `token()`.
contract MockERC20Tornado {
    using SafeERC20 for IERC20;

    uint256 public constant denomination = 100 ether;
    IERC20 public immutable token;

    constructor(IERC20 _token) {
        token = _token;
    }

    function withdraw(
        bytes calldata,
        bytes32,
        bytes32,
        address payable recipient,
        address payable relayer,
        uint256 fee,
        uint256 refund
    ) external payable {
        require(msg.value == refund, "refund");
        token.safeTransfer(recipient, denomination - fee);
        token.safeTransfer(relayer, fee);
    }

    function test() public {}
}
