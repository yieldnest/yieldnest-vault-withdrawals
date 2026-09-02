// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IWithdrawer {
    /// @notice Withdraws assets for a request and returns the amount of shares consumed.
    /// @param requestId Request id being resolved.
    /// @param asset Asset to withdraw.
    /// @param assets Amount of `asset` to withdraw.
    /// @param receiver Receiver of the withdrawn asset.
    /// @param owner Owner address whose shares may be burned or transferred.
    /// @return shares Amount of shares consumed by the withdrawal.
    function withdrawAsset(uint256 requestId, address asset, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Converts shares to assets at the withdrawer's redemption rate.
    /// @param shares Amount of shares to convert.
    /// @return assets Amount of assets implied by the redemption rate.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
