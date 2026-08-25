// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";

library VaultMath {
    using Math for uint256;

    /// @notice Converts yn-token shares into the maximum amount of a vault asset withdrawable from a vault.
    /// @dev Rounds down so callers do not intentionally request assets requiring more shares than budgeted.
    /// @param token Vault token whose accounting is used for conversion.
    /// @param asset Asset to estimate.
    /// @param shares Amount of yn-token shares to convert.
    /// @return assets Estimated amount of `asset` withdrawable for `shares`.
    function convertToAssets(IVault token, address asset, uint256 shares) internal view returns (uint256 assets) {
        uint256 totalSupply = token.totalSupply();
        uint256 totalBaseAssets = token.totalBaseAssets();
        uint256 baseAssets = shares.mulDiv(totalBaseAssets + 1, totalSupply + 1, Math.Rounding.Floor);

        IVault.AssetParams memory assetParams = token.getAsset(asset);
        uint256 rate = IProvider(token.provider()).getRate(asset);
        assets = baseAssets.mulDiv(10 ** assetParams.decimals, rate, Math.Rounding.Floor);
    }
}
