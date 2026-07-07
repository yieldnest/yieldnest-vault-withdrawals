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
        uint256 id;
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

        view_ = _getRequest(id, request, token, assets, manager);
    }

    /// @notice Returns in-progress requests currently owned by `owner`.
    /// @dev Iterates request ids from 1 to `nextRequestId() - 1`; intended for offchain/UI reads.
    function getInProgressRequestsForOwner(WithdrawalRequestManager manager, address owner)
        external
        view
        returns (RequestView[] memory requests_)
    {
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(manager.token()));
        address[] memory assets = token.getAssets();
        uint256 nextRequestId = manager.nextRequestId();
        uint256 count;

        for (uint256 id = 1; id < nextRequestId; ++id) {
            if (_matchesOwner(manager, id, owner)) count++;
        }

        requests_ = new RequestView[](count);
        uint256 index;
        for (uint256 id = 1; id < nextRequestId; ++id) {
            if (_matchesOwner(manager, id, owner)) {
                requests_[index++] = _getRequest(id, manager.requests(id), token, assets, manager);
            }
        }
    }

    function _getRequest(
        uint256 id,
        WithdrawalRequestManager.WithdrawalRequest memory request,
        IWithdrawalRequestViewerVault token,
        address[] memory assets,
        WithdrawalRequestManager manager
    ) internal view returns (RequestView memory view_) {
        AssetBalance[] memory assetBalances = new AssetBalance[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            assetBalances[i] = AssetBalance({asset: assets[i], balance: IERC20(assets[i]).balanceOf(request.bag)});
        }

        view_ = RequestView({
            id: id,
            owner: IBag(request.bag).ownerOf(IBag(request.bag).TOKEN_ID()),
            bag: request.bag,
            token: address(token),
            amountLocked: request.amountLocked,
            tokenBalance: token.balanceOf(address(manager)),
            assetBalances: assetBalances
        });
    }

    function _matchesOwner(WithdrawalRequestManager manager, uint256 id, address owner) internal view returns (bool) {
        if (!manager.requestExists(id)) return false;

        WithdrawalRequestManager.WithdrawalRequest memory request = manager.requests(id);
        if (request.amountLocked == 0) return false;

        return IBag(request.bag).ownerOf(IBag(request.bag).TOKEN_ID()) == owner;
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
