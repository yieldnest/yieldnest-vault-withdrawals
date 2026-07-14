// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IResolver {
    error ArrayLengthMismatch(uint256 assetsLength, uint256 shareAmountsLength);

    function resolveWithdrawalRequest(uint256 id, address asset, uint256 sharesToResolve)
        external
        returns (uint256 amountBurned);

    function resolveWithdrawalRequest(uint256 id, address[] calldata assets, uint256[] calldata shareAmounts)
        external
        returns (uint256[] memory amountsBurned);
}
