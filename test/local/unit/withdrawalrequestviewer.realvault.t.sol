// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {SetupWithdrawalRequest} from "test/local/unit/helpers/SetupWithdrawalRequest.sol";

contract WithdrawalRequestViewerRealVaultTest is SetupWithdrawalRequest {
    using Math for uint256;

    function setUp() public {
        setUpWithdrawalRequest();
    }

    function testConvertToAssetsUsesRealVaultDefaultAssetConversion() public view {
        uint256 shares = 10 ether;

        assertEq(viewer.convertToAssets(manager, address(asset), shares), ynToken.convertToAssets(shares));
    }

    function testConvertToAssetsUsesRealVaultRequestedAssetRate() public {
        _setAssetRate(address(secondAsset), 2 ether);
        ynToken.processAccounting();

        uint256 shares = 10 ether;

        assertEq(
            viewer.convertToAssets(manager, address(secondAsset), shares),
            _expectedConvertToAssets(address(secondAsset), shares)
        );
    }

    function testConvertToAssetsReflectsRealVaultYieldAfterAccounting() public {
        uint256 shares = 10 ether;
        uint256 beforeAssets = viewer.convertToAssets(manager, address(asset), shares);

        asset.mint(address(ynToken), 10 ether);
        ynToken.processAccounting();

        uint256 afterAssets = viewer.convertToAssets(manager, address(asset), shares);

        assertGt(afterAssets, beforeAssets);
        assertEq(afterAssets, _expectedConvertToAssets(address(asset), shares));
    }

    function _expectedConvertToAssets(address asset_, uint256 shares) internal view returns (uint256) {
        uint256 baseAssets =
            shares.mulDiv(ynToken.totalBaseAssets() + 1, ynToken.totalSupply() + 1, Math.Rounding.Floor);
        IVault.AssetParams memory assetParams = ynToken.getAsset(asset_);
        uint256 rate = IProvider(ynToken.provider()).getRate(asset_);
        return baseAssets.mulDiv(10 ** assetParams.decimals, rate, Math.Rounding.Floor);
    }
}
