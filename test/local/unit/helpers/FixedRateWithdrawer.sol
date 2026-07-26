// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";

/// @title FixedRateWithdrawer
/// @notice Test-only withdrawer adapter that enforces a minimum redemption rate for the vault default asset.
contract FixedRateWithdrawer is BaseWithdrawer {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public immutable fixedRate;
    address public immutable collector;

    error InvalidAsset(address asset);
    error InvalidRate();

    /// @notice Deploys a fixed-rate withdrawer for the vault default asset.
    /// @param token_ Vault token to withdraw assets from.
    /// @param withdrawalRequest_ Withdrawal request contract authorized to call this withdrawer.
    /// @param fixedRate_ Fixed default-asset amount per whole share unit.
    /// @param collector_ Receiver of shares charged above the vault-burned amount.
    constructor(address token_, address withdrawalRequest_, uint256 fixedRate_, address collector_)
        BaseWithdrawer(token_, withdrawalRequest_)
    {
        if (fixedRate_ == 0) revert InvalidRate();
        if (collector_ == address(0)) revert ZeroAddress();

        fixedRate = fixedRate_;
        collector = collector_;
    }

    /// @notice Withdraws the vault default asset while charging shares at the fixed redemption rate.
    /// @param asset Asset to withdraw, which must be the vault default asset.
    /// @param assets Amount of `asset` to withdraw.
    /// @param receiver Receiver of the withdrawn asset.
    /// @param owner Owner whose shares are burned or transferred to the collector.
    /// @return shares Amount of shares consumed at the fixed-rate policy.
    function withdrawAsset(uint256, address asset, uint256 assets, address receiver, address owner)
        external
        override
        onlyWithdrawalRequest
        returns (uint256 shares)
    {
        address defaultAsset = token().asset();
        if (asset != defaultAsset) revert InvalidAsset(asset);

        uint256 fixedRateShares = _convertToShares(assets);

        uint256 sharesBurned = token().withdrawAsset(asset, assets, receiver, owner);
        if (fixedRateShares <= sharesBurned) return sharesBurned;

        IERC20(address(token())).safeTransferFrom(owner, collector, fixedRateShares - sharesBurned);
        return fixedRateShares;
    }

    /// @notice Converts shares to default-asset units at the fixed redemption rate.
    /// @param shares Amount of shares to convert.
    /// @return assets Amount of default asset implied by the fixed rate.
    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        return shares.mulDiv(fixedRate, _shareUnit(), Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets) internal view returns (uint256 shares) {
        return assets.mulDiv(_shareUnit(), fixedRate, Math.Rounding.Ceil);
    }

    function _shareUnit() internal view returns (uint256) {
        return 10 ** token().decimals();
    }
}
