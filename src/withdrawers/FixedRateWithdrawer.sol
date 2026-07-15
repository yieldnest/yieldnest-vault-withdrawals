// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";

interface IDefaultAssetVault {
    function asset() external view returns (address);
}

/// @title FixedRateWithdrawer
/// @notice Withdrawer adapter that enforces a minimum redemption rate for the vault default asset.
contract FixedRateWithdrawer is BaseWithdrawer {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public immutable fixedRate;
    address public immutable collector;

    error InvalidAsset(address asset);
    error InvalidRate();

    constructor(address token_, address withdrawalRequest_, uint256 fixedRate_, address collector_)
        BaseWithdrawer(token_, withdrawalRequest_)
    {
        if (fixedRate_ == 0) revert InvalidRate();
        if (collector_ == address(0)) revert ZeroAddress();

        fixedRate = fixedRate_;
        collector = collector_;
    }

    function withdrawAsset(uint256, address asset, uint256 assets, address receiver, address owner)
        external
        override
        returns (uint256 shares)
    {
        _checkWithdrawalRequest();

        address defaultAsset = IDefaultAssetVault(address(token)).asset();
        if (asset != defaultAsset) revert InvalidAsset(asset);

        uint256 shareUnit = 10 ** token.decimals();
        uint256 fixedRateShares = assets.mulDiv(shareUnit, fixedRate, Math.Rounding.Ceil);

        uint256 sharesBurned = token.withdrawAsset(asset, assets, receiver, owner);
        if (fixedRateShares <= sharesBurned) return sharesBurned;

        IERC20(address(token)).safeTransferFrom(owner, collector, fixedRateShares - sharesBurned);
        return fixedRateShares;
    }
}
