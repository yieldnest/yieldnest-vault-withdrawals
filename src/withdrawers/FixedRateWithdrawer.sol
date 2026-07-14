// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";

interface IDefaultAssetVault {
    function asset() external view returns (address);
}

/// @title FixedRateWithdrawer
/// @notice Withdrawer adapter that enforces a minimum redemption rate for the vault default asset.
contract FixedRateWithdrawer is BaseWithdrawer {
    using Math for uint256;

    uint256 public immutable fixedRate;

    error InvalidAsset(address asset);
    error InvalidRate();
    error RateUnavailable(uint256 sharesBurned, uint256 maxShares);

    constructor(address token_, address withdrawalRequest_, uint256 fixedRate_)
        BaseWithdrawer(token_, withdrawalRequest_)
    {
        if (fixedRate_ == 0) revert InvalidRate();
        fixedRate = fixedRate_;
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
        uint256 maxShares = assets.mulDiv(shareUnit, fixedRate, Math.Rounding.Ceil);

        shares = token.withdrawAsset(asset, assets, receiver, owner);
        if (shares > maxShares) revert RateUnavailable(shares, maxShares);
    }
}
