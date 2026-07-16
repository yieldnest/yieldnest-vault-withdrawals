// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IWithdrawer {
    function withdrawAsset(uint256 requestId, address asset, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
