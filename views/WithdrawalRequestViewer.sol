// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";

interface IWithdrawalRequestViewerVault is IERC20, IERC20Metadata {
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
        uint256 rateAtRequest;
        uint256 tokenBalance;
        bool isClaimable;
        bool isClaimed;
        AssetBalance[] assetBalances;
    }

    function getRequest(WithdrawalRequest withdrawalRequest, uint256 id) external view returns (RequestView memory view_) {
        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(withdrawalRequest.token()));

        view_ = _getRequest(id, request, token, withdrawalRequest);
    }

    /// @notice Returns requests currently owned by `owner`.
    function getInProgressRequestsForOwner(WithdrawalRequest withdrawalRequest, address owner)
        external
        view
        returns (RequestView[] memory requests_)
    {
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(withdrawalRequest.token()));
        uint256 count = withdrawalRequest.balanceOf(owner);

        requests_ = new RequestView[](count);
        for (uint256 i = 0; i < count; ++i) {
            uint256 id = withdrawalRequest.tokenOfOwnerByIndex(owner, i);
            requests_[i] = _getRequest(id, withdrawalRequest.requests(id), token, withdrawalRequest);
        }
    }

    function _getRequest(
        uint256 id,
        WithdrawalRequest.Request memory request,
        IWithdrawalRequestViewerVault token,
        WithdrawalRequest withdrawalRequest
    ) internal view returns (RequestView memory view_) {
        AssetBalance[] memory assetBalances = new AssetBalance[](request.assetsRedeemed.length);
        for (uint256 i = 0; i < request.assetsRedeemed.length; ++i) {
            address asset = request.assetsRedeemed[i];
            assetBalances[i] = AssetBalance({asset: asset, balance: IERC20(asset).balanceOf(request.bag)});
        }

        bool isClaimable = _requestIsClaimable(request, token);
        view_ = RequestView({
            id: id,
            owner: withdrawalRequest.ownerOf(id),
            bag: request.bag,
            token: address(token),
            amountLocked: request.amountLocked,
            rateAtRequest: request.rateAtRequest,
            tokenBalance: token.balanceOf(address(withdrawalRequest)),
            isClaimable: isClaimable,
            isClaimed: _requestIsClaimed(request, token),
            assetBalances: assetBalances
        });
    }

    /// @notice Returns true when the remaining locked yn-token amount is below the dust threshold.
    /// @dev UI-only heuristic: this indicates that most of the position has been withdrawn.
    /// It works well for ETH and USDC-style assets where resolution can leave a trace
    /// amount of locked yn-token behind. It is not a protocol-level claimability invariant.
    function requestIsClaimable(WithdrawalRequest withdrawalRequest, uint256 id) external view returns (bool) {
        if (!withdrawalRequest.requestExists(id)) return false;

        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(withdrawalRequest.token()));

        return _requestIsClaimable(request, token);
    }

    /// @notice Returns true when the request is claimable and its bag has no balances for redeemed assets.
    function requestIsClaimed(WithdrawalRequest withdrawalRequest, uint256 id) external view returns (bool) {
        if (!withdrawalRequest.requestExists(id)) return false;

        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(withdrawalRequest.token()));

        return _requestIsClaimed(request, token);
    }

    function _requestIsClaimable(
        WithdrawalRequest.Request memory request,
        IWithdrawalRequestViewerVault token
    ) internal view returns (bool) {
        return request.amountLocked < 10 ** token.decimals() / 1e4;
    }

    function _requestIsClaimed(
        WithdrawalRequest.Request memory request,
        IWithdrawalRequestViewerVault token
    ) internal view returns (bool) {
        if (!_requestIsClaimable(request, token)) return false;

        for (uint256 i = 0; i < request.assetsRedeemed.length; ++i) {
            if (IERC20(request.assetsRedeemed[i]).balanceOf(request.bag) != 0) return false;
        }

        return true;
    }

    /// @notice Converts yn-token shares into the maximum amount of a vault asset withdrawable from the configured token.
    /// @dev Rounds down so callers do not intentionally request assets requiring more shares than are locked.
    function convertToAssets(WithdrawalRequest withdrawalRequest, address asset, uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(withdrawalRequest.token()));
        uint256 totalSupply = token.totalSupply();
        uint256 totalBaseAssets = token.totalBaseAssets();
        uint256 baseAssets = shares.mulDiv(totalBaseAssets + 1, totalSupply + 1, Math.Rounding.Floor);

        IVault.AssetParams memory assetParams = token.getAsset(asset);
        uint256 rate = IProvider(token.provider()).getRate(asset);
        assets = baseAssets.mulDiv(10 ** assetParams.decimals, rate, Math.Rounding.Floor);
    }

    /// @notice Returns the asset amount a caller can pass to `resolveWithdrawalRequest` for the request's locked shares.
    function maxResolutionAssets(WithdrawalRequest withdrawalRequest, uint256 id, address asset)
        external
        view
        returns (uint256 assets)
    {
        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        assets = convertToAssets(withdrawalRequest, asset, request.amountLocked);
    }
}
