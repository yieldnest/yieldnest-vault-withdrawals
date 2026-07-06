// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IBag} from "src/interface/IBag.sol";
import {WithdrawalRequestManager} from "src/WithdrawalRequestManager.sol";

interface IWithdrawalRequestViewerVault is IERC20 {
    function getAssets() external view returns (address[] memory);
    function getAsset(address asset_) external view returns (IVault.AssetParams memory);
    function provider() external view returns (address);
    function totalBaseAssets() external view returns (uint256);
}

/// @title WithdrawalRequestViewer
/// @notice Read-only helper for request, bag, and vault asset balances.
contract WithdrawalRequestViewer {
    using Math for uint256;

    struct AssetBalance {
        address asset;
        uint256 balance;
    }

    struct RequestView {
        address owner;
        address bag;
        address token;
        uint256 amountLocked;
        uint256 tokenBalance;
        AssetBalance[] assetBalances;
    }

    function getRequest(WithdrawalRequestManager manager, uint256 id) external view returns (RequestView memory view_) {
        WithdrawalRequestManager.WithdrawalRequest memory request = manager.requests(id);
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(manager.token()));
        address[] memory assets = token.getAssets();

        AssetBalance[] memory assetBalances = new AssetBalance[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            assetBalances[i] = AssetBalance({asset: assets[i], balance: IERC20(assets[i]).balanceOf(request.bag)});
        }

        view_ = RequestView({
            owner: IBag(request.bag).ownerOf(IBag(request.bag).TOKEN_ID()),
            bag: request.bag,
            token: address(token),
            amountLocked: request.amountLocked,
            tokenBalance: token.balanceOf(address(manager)),
            assetBalances: assetBalances
        });
    }

    /// @notice Converts yn-token shares into the maximum amount of a vault asset withdrawable from the configured token.
    /// @dev Rounds down so callers do not intentionally request assets requiring more shares than are locked.
    function convertToAssets(WithdrawalRequestManager manager, address asset, uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(manager.token()));
        uint256 totalSupply = token.totalSupply();
        uint256 totalBaseAssets = token.totalBaseAssets();
        uint256 baseAssets = shares.mulDiv(totalBaseAssets + 1, totalSupply + 1, Math.Rounding.Floor);

        IVault.AssetParams memory assetParams = token.getAsset(asset);
        uint256 rate = IProvider(token.provider()).getRate(asset);
        assets = baseAssets.mulDiv(10 ** assetParams.decimals, rate, Math.Rounding.Floor);
    }

    /// @notice Returns the asset amount a caller can pass to `fulfillWithdrawalRequest` for the request's locked shares.
    function maxFulfillmentAssets(WithdrawalRequestManager manager, uint256 id, address asset)
        external
        view
        returns (uint256 assets)
    {
        WithdrawalRequestManager.WithdrawalRequest memory request = manager.requests(id);
        assets = convertToAssets(manager, asset, request.amountLocked);
    }
}
