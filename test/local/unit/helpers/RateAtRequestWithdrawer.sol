// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IWithdrawalRequest} from "src/interface/IWithdrawalRequest.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";

/// @notice Test-only withdrawer that charges each request at its recorded request-time rate.
contract RateAtRequestWithdrawer is IWithdrawer {
    using Math for uint256;
    using SafeERC20 for IERC20;

    WithdrawalRequest internal immutable manager;
    IVault internal immutable token;
    address internal immutable feeAddress;

    error Unauthorized(address caller);
    error InvalidAsset(address asset);

    constructor(address manager_, address token_, address feeAddress_) {
        manager = WithdrawalRequest(manager_);
        token = IVault(token_);
        feeAddress = feeAddress_;
    }

    function withdrawAsset(uint256 requestId, address asset, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        if (msg.sender != address(manager)) revert Unauthorized(msg.sender);
        if (asset != token.asset()) revert InvalidAsset(asset);

        IWithdrawalRequest.Request memory request = manager.requests(requestId);
        uint256 sharesAtRequestRate = assets.mulDiv(10 ** token.decimals(), request.rateAtRequest, Math.Rounding.Ceil);

        uint256 sharesBurned = token.withdrawAsset(asset, assets, receiver, owner);
        if (sharesAtRequestRate <= sharesBurned) return sharesBurned;

        IERC20(address(token)).safeTransferFrom(owner, feeAddress, sharesAtRequestRate - sharesBurned);
        return sharesAtRequestRate;
    }

    function convertToAssets(uint256 requestId, address asset, uint256 shares) external view returns (uint256 assets) {
        if (asset != token.asset()) revert InvalidAsset(asset);

        IWithdrawalRequest.Request memory request = manager.requests(requestId);
        return shares.mulDiv(request.rateAtRequest, 10 ** token.decimals(), Math.Rounding.Floor);
    }
}
