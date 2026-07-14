// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IRedemptionRateProvider} from "src/interface/IRedemptionRateProvider.sol";

interface IRequestRateProviderVault is IERC20Metadata {
    function getAsset(address asset_) external view returns (IVault.AssetParams memory);
    function provider() external view returns (address);
}

/// @title RequestRateProvider
/// @notice Converts shares to redemption assets using the rate recorded when the request was created.
contract RequestRateProvider is IRedemptionRateProvider {
    using Math for uint256;

    error InvalidRate();

    function redemptionAssets(address token, uint256, Request calldata request, address asset, uint256 sharesToResolve)
        external
        view
        returns (uint256 assets)
    {
        if (request.rateAtRequest == 0) revert InvalidRate();

        IRequestRateProviderVault vault = IRequestRateProviderVault(token);
        uint256 shareUnit = 10 ** vault.decimals();
        uint256 baseAssets = sharesToResolve.mulDiv(request.rateAtRequest, shareUnit, Math.Rounding.Floor);

        IVault.AssetParams memory assetParams = vault.getAsset(asset);
        uint256 assetRate = IProvider(vault.provider()).getRate(asset);
        if (assetRate == 0) revert InvalidRate();

        assets = baseAssets.mulDiv(10 ** assetParams.decimals, assetRate, Math.Rounding.Floor);
    }
}
