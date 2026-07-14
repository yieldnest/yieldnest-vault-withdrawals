// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IRedemptionRateProvider {
    struct Request {
        address bag;
        uint256 amountLocked;
        address[] assetsRedeemed;
        uint256 rateAtRequest;
    }

    function redemptionAssets(
        address token,
        uint256 id,
        Request calldata request,
        address asset,
        uint256 sharesToResolve
    ) external view returns (uint256 assets);
}
