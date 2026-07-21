// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
