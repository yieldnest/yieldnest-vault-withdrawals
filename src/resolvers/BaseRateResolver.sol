// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IResolver} from "src/interface/IResolver.sol";
import {IWithdrawAssetVault, WithdrawalRequest} from "src/WithdrawalRequest.sol";

interface IRateResolverVault is IWithdrawAssetVault {
    function getAsset(address asset_) external view returns (IVault.AssetParams memory);
    function provider() external view returns (address);
}

/// @title BaseRateResolver
/// @notice Shared resolver logic for charging a flat yn-token share fee from rate differences.
abstract contract BaseRateResolver is AccessControl, IResolver {
    using Math for uint256;

    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    WithdrawalRequest public immutable withdrawalRequest;

    error InvalidRate();
    error RateUnavailable(uint256 currentRate, uint256 targetRate);

    constructor(WithdrawalRequest withdrawalRequest_, address defaultAdmin, address resolver) {
        if (address(withdrawalRequest_) == address(0) || defaultAdmin == address(0) || resolver == address(0)) {
            revert WithdrawalRequest.ZeroAddress();
        }

        withdrawalRequest = withdrawalRequest_;
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(RESOLVER_ROLE, resolver);
    }

    function resolveWithdrawalRequest(uint256 id, address asset, uint256 assets)
        external
        onlyRole(RESOLVER_ROLE)
        returns (uint256 amountBurned)
    {
        uint256 fee = resolutionFee(id, asset, assets);
        amountBurned = withdrawalRequest.resolveWithdrawalRequest(id, asset, assets, fee);
    }

    function resolveWithdrawalRequest(uint256 id, address[] calldata assets, uint256[] calldata assetAmounts)
        external
        onlyRole(RESOLVER_ROLE)
        returns (uint256[] memory amountsBurned)
    {
        if (assets.length != assetAmounts.length) {
            revert ArrayLengthMismatch(assets.length, assetAmounts.length);
        }

        amountsBurned = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            uint256 fee = resolutionFee(id, assets[i], assetAmounts[i]);
            amountsBurned[i] = withdrawalRequest.resolveWithdrawalRequest(id, assets[i], assetAmounts[i], fee);
        }
    }

    function resolutionFee(uint256 id, address asset, uint256 assets) public view returns (uint256 fee) {
        uint256 targetRate = _resolutionRate(id);
        if (targetRate == 0) revert InvalidRate();

        IRateResolverVault token = IRateResolverVault(address(withdrawalRequest.token()));
        uint256 shareUnit = 10 ** token.decimals();
        uint256 currentRate = token.convertToAssets(shareUnit);
        if (currentRate < targetRate) revert RateUnavailable(currentRate, targetRate);
        if (currentRate == targetRate) return 0;

        IVault.AssetParams memory assetParams = token.getAsset(asset);
        uint256 assetUnit = 10 ** assetParams.decimals;
        uint256 assetRate = IProvider(token.provider()).getRate(asset);
        if (assetRate == 0) revert InvalidRate();

        uint256 baseAssets = assets.mulDiv(assetRate, assetUnit, Math.Rounding.Ceil);
        uint256 targetShares = baseAssets.mulDiv(shareUnit, targetRate, Math.Rounding.Ceil);
        uint256 currentShares = baseAssets.mulDiv(shareUnit, currentRate, Math.Rounding.Ceil);
        fee = targetShares - currentShares;
    }

    function _resolutionRate(uint256 id) internal view virtual returns (uint256);
}
