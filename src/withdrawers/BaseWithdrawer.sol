// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";

interface IWithdrawerVault is IERC20Metadata {
    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
}

/// @title BaseWithdrawer
/// @notice Authorized adapter that forwards withdrawal requests to the configured vault.
contract BaseWithdrawer is IWithdrawer {
    IWithdrawerVault public immutable token;
    address public immutable withdrawalRequest;

    error Unauthorized(address caller);
    error ZeroAddress();

    constructor(address token_, address withdrawalRequest_) {
        if (token_ == address(0) || withdrawalRequest_ == address(0)) revert ZeroAddress();

        token = IWithdrawerVault(token_);
        withdrawalRequest = withdrawalRequest_;
    }

    function withdrawAsset(uint256, address asset, uint256 assets, address receiver, address owner)
        external
        virtual
        returns (uint256 shares)
    {
        _checkWithdrawalRequest();
        shares = token.withdrawAsset(asset, assets, receiver, owner);
    }

    function _checkWithdrawalRequest() internal view {
        if (msg.sender != withdrawalRequest) revert Unauthorized(msg.sender);
    }
}
