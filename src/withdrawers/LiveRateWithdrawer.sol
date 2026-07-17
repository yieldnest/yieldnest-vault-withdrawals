// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";

interface IWithdrawerVault is IERC20Metadata {
    /// @notice Withdraws a vault asset to a receiver and consumes shares from owner.
    /// @param asset_ Asset to withdraw.
    /// @param assets Amount of `asset_` to withdraw.
    /// @param receiver Receiver of the withdrawn asset.
    /// @param owner Owner whose shares are consumed.
    /// @return shares Amount of shares consumed.
    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Converts shares to the vault default asset amount.
    /// @param shares Amount of shares to convert.
    /// @return assets Amount of default asset represented by `shares`.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/// @title LiveRateWithdrawer
/// @notice Authorized adapter that forwards withdrawals to the configured vault at its live redemption rate.
contract LiveRateWithdrawer is IWithdrawer {
    IWithdrawerVault public immutable token;
    address public immutable withdrawalRequest;

    error Unauthorized(address caller);
    error ZeroAddress();

    /// @notice Deploys a withdrawer bound to one vault and one withdrawal request contract.
    /// @param token_ Vault token to withdraw assets from.
    /// @param withdrawalRequest_ Withdrawal request contract authorized to call this withdrawer.
    constructor(address token_, address withdrawalRequest_) {
        if (token_ == address(0) || withdrawalRequest_ == address(0)) revert ZeroAddress();

        token = IWithdrawerVault(token_);
        withdrawalRequest = withdrawalRequest_;
    }

    /// @notice Forwards a withdrawal request to the configured vault.
    /// @param asset Asset to withdraw.
    /// @param assets Amount of `asset` to withdraw.
    /// @param receiver Receiver of the withdrawn asset.
    /// @param owner Owner whose shares are consumed.
    /// @return shares Amount of shares consumed by the vault.
    function withdrawAsset(uint256, address asset, uint256 assets, address receiver, address owner)
        external
        virtual
        returns (uint256 shares)
    {
        _checkWithdrawalRequest();
        shares = token.withdrawAsset(asset, assets, receiver, owner);
    }

    /// @notice Converts shares to assets using the configured vault rate.
    /// @param shares Amount of shares to convert.
    /// @return assets Amount of assets represented by `shares`.
    function convertToAssets(uint256 shares) public view virtual returns (uint256 assets) {
        return token.convertToAssets(shares);
    }

    function _checkWithdrawalRequest() internal view {
        if (msg.sender != withdrawalRequest) revert Unauthorized(msg.sender);
    }
}
