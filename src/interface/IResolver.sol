// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IResolver {
    /// @notice Resolves part or all of a withdrawal request into one asset.
    /// @param id Request id to resolve.
    /// @param asset Asset to withdraw into the request bag.
    /// @param assets Amount of `asset` to withdraw.
    /// @return amountBurned Amount of locked shares consumed by the resolution.
    function resolveWithdrawalRequest(uint256 id, address asset, uint256 assets) external returns (uint256 amountBurned);

    /// @notice Resolves part or all of a withdrawal request across multiple assets.
    /// @param id Request id to resolve.
    /// @param assets Assets to withdraw into the request bag.
    /// @param assetAmounts Amounts to withdraw for each asset.
    /// @return amountsBurned Amounts of locked shares consumed by each resolution.
    function resolveWithdrawalRequest(uint256 id, address[] calldata assets, uint256[] calldata assetAmounts)
        external
        returns (uint256[] memory amountsBurned);
}
