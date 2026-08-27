// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {VaultMath} from "src/library/VaultMath.sol";

/// @title WithdrawalRequestViewer
/// @notice Read-only helper for request, bag, and vault asset balances.
contract WithdrawalRequestViewer {
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
        bytes data;
        uint256 tokenBalance;
        bool isFullyRedeemed;
        bool hasClaimableAssets;
        bool isClaimed;
        AssetBalance[] assetBalances;
    }

    /// @notice Returns the full view of one withdrawal request.
    /// @param withdrawalRequest Withdrawal request contract to inspect.
    /// @param id Request id to inspect.
    /// @return view_ Aggregated request, owner, bag, and asset balance data.
    function getRequest(WithdrawalRequest withdrawalRequest, uint256 id)
        external
        view
        returns (RequestView memory view_)
    {
        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        IVault token = IVault(address(withdrawalRequest.token()));

        view_ = _getRequest(id, request, token, withdrawalRequest);
    }

    /// @notice Returns requests currently owned by `owner`.
    /// @param withdrawalRequest Withdrawal request contract to inspect.
    /// @param owner Request NFT owner to query.
    /// @return requests_ Aggregated views for all request NFTs currently owned by `owner`.
    function getInProgressRequestsForOwner(WithdrawalRequest withdrawalRequest, address owner)
        external
        view
        returns (RequestView[] memory requests_)
    {
        IVault token = IVault(address(withdrawalRequest.token()));
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
        IVault token,
        WithdrawalRequest withdrawalRequest
    ) internal view returns (RequestView memory view_) {
        AssetBalance[] memory assetBalances = new AssetBalance[](request.assetsRedeemed.length);
        for (uint256 i = 0; i < request.assetsRedeemed.length; ++i) {
            address asset = request.assetsRedeemed[i];
            assetBalances[i] = AssetBalance({asset: asset, balance: IERC20(asset).balanceOf(request.bag)});
        }

        bool isFullyRedeemed = _requestIsFullyRedeemed(request, token);
        bool hasClaimableAssets = _requestHasClaimableAssets(request);
        view_ = RequestView({
            id: id,
            owner: withdrawalRequest.ownerOf(id),
            bag: request.bag,
            token: address(token),
            amountLocked: request.amountLocked,
            rateAtRequest: request.rateAtRequest,
            data: request.data,
            tokenBalance: token.balanceOf(address(withdrawalRequest)),
            isFullyRedeemed: isFullyRedeemed,
            hasClaimableAssets: hasClaimableAssets,
            isClaimed: _requestIsClaimed(request, token),
            assetBalances: assetBalances
        });
    }

    /// @notice Returns true when the remaining locked yn-token amount is below the dust threshold.
    /// @dev UI-only heuristic: this indicates that most of the position has been withdrawn.
    /// It works well for ETH and USDC-style assets where resolution can leave a trace
    /// amount of locked yn-token behind. It is not a protocol-level claimability invariant.
    /// @param withdrawalRequest Withdrawal request contract to inspect.
    /// @param id Request id to inspect.
    /// @return True if the request exists and its remaining locked shares are below the dust threshold.
    function requestIsFullyRedeemed(WithdrawalRequest withdrawalRequest, uint256 id) external view returns (bool) {
        if (!withdrawalRequest.requestExists(id)) return false;

        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        IVault token = IVault(address(withdrawalRequest.token()));

        return _requestIsFullyRedeemed(request, token);
    }

    /// @notice Returns true when the request has at least one tracked redeemed asset available to claim.
    /// @param withdrawalRequest Withdrawal request contract to inspect.
    /// @param id Request id to inspect.
    /// @return True if the request exists and any tracked redeemed asset has a nonzero bag balance.
    function requestHasClaimableAssets(WithdrawalRequest withdrawalRequest, uint256 id) external view returns (bool) {
        if (!withdrawalRequest.requestExists(id)) return false;

        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        return _requestHasClaimableAssets(request);
    }

    /// @notice Returns true when the request is fully redeemed and its bag has no balances for redeemed assets.
    /// @param withdrawalRequest Withdrawal request contract to inspect.
    /// @param id Request id to inspect.
    /// @return True if the request is fully redeemed and all tracked bag asset balances are zero.
    function requestIsClaimed(WithdrawalRequest withdrawalRequest, uint256 id) external view returns (bool) {
        if (!withdrawalRequest.requestExists(id)) return false;

        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        IVault token = IVault(address(withdrawalRequest.token()));

        return _requestIsClaimed(request, token);
    }

    function _requestIsFullyRedeemed(WithdrawalRequest.Request memory request, IVault token)
        internal
        view
        returns (bool)
    {
        return request.amountLocked < 10 ** token.decimals() / 1e4;
    }

    function _requestIsClaimed(WithdrawalRequest.Request memory request, IVault token) internal view returns (bool) {
        if (!_requestIsFullyRedeemed(request, token)) return false;

        for (uint256 i = 0; i < request.assetsRedeemed.length; ++i) {
            if (IERC20(request.assetsRedeemed[i]).balanceOf(request.bag) != 0) return false;
        }

        return true;
    }

    function _requestHasClaimableAssets(WithdrawalRequest.Request memory request) internal view returns (bool) {
        for (uint256 i = 0; i < request.assetsRedeemed.length; ++i) {
            if (IERC20(request.assetsRedeemed[i]).balanceOf(request.bag) != 0) return true;
        }

        return false;
    }

    /// @notice Converts yn-token shares into the maximum amount of a vault asset withdrawable from the configured token.
    /// @dev Rounds down so callers do not intentionally request assets requiring more shares than are locked.
    /// @param withdrawalRequest Withdrawal request contract whose token is used for conversion.
    /// @param asset Asset to estimate.
    /// @param shares Amount of yn-token shares to convert.
    /// @return assets Estimated amount of `asset` withdrawable for `shares`.
    function convertToAssets(WithdrawalRequest withdrawalRequest, address asset, uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        IVault token = IVault(address(withdrawalRequest.token()));
        assets = VaultMath.convertToAssets(token, asset, shares);
    }

    /// @notice Converts yn-token shares to default-asset units using the configured redemption withdrawer.
    /// @dev This reflects the rate that the current withdrawer applies for redemption UI display.
    /// For `BaseWithdrawer`, this delegates to the vault's ERC4626-style `convertToAssets`.
    /// For fixed-rate withdrawers, this returns the assets implied by the fixed redemption rate.
    /// It is intentionally separate from `convertToAssets`, which estimates per-asset resolution amounts.
    /// @param withdrawalRequest Withdrawal request contract whose configured withdrawer provides the redemption rate.
    /// @param shares Amount of yn-token shares to convert.
    /// @return assets Amount of the vault default asset implied by the configured redemption rate.
    function convertToAssetsAtRedemptionRate(WithdrawalRequest withdrawalRequest, uint256 shares)
        external
        view
        returns (uint256 assets)
    {
        assets = withdrawalRequest.withdrawer().convertToAssets(shares);
    }

    /// @notice Returns the minimum yn-token share amount required to create a withdrawal request.
    /// @dev Reads the value from the currently configured request policy, so it reflects policy updates.
    /// @param withdrawalRequest Withdrawal request contract whose policy defines request admission rules.
    /// @return amount Minimum amount of yn-token shares that can be locked in a new request.
    function minWithdrawalAmount(WithdrawalRequest withdrawalRequest) external view returns (uint256 amount) {
        amount = withdrawalRequest.requestPolicy().minWithdrawalAmount();
    }

    /// @notice Returns the asset amount a caller can pass to `resolveWithdrawalRequest` for the request's locked shares.
    /// @param withdrawalRequest Withdrawal request contract to inspect.
    /// @param id Request id whose locked shares are converted.
    /// @param asset Asset to estimate.
    /// @return assets Estimated maximum amount of `asset` resolvable for the request.
    function maxResolutionAssets(WithdrawalRequest withdrawalRequest, uint256 id, address asset)
        external
        view
        returns (uint256 assets)
    {
        WithdrawalRequest.Request memory request = withdrawalRequest.requests(id);
        IVault token = IVault(address(withdrawalRequest.token()));

        assets = convertToAssets(withdrawalRequest, asset, request.amountLocked);

        uint256 tokenAssetBalance = IERC20(asset).balanceOf(address(token));
        if (assets > tokenAssetBalance) assets = tokenAssetBalance;
    }
}
