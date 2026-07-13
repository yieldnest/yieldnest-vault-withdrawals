// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IResolver} from "src/interface/IResolver.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";

/// @title NoOpResolver
/// @notice Resolver adapter that forwards resolutions without charging a fee.
contract NoOpResolver is AccessControl, IResolver {
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    WithdrawalRequest public immutable withdrawalRequest;

    constructor(WithdrawalRequest withdrawalRequest_, address defaultAdmin, address resolver) {
        if (address(withdrawalRequest_) == address(0) || defaultAdmin == address(0) || resolver == address(0)) {
            revert WithdrawalRequest.ZeroAddress();
        }

        withdrawalRequest = withdrawalRequest_;
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(RESOLVER_ROLE, resolver);
    }

    function resolveWithdrawalRequest(uint256 id, address asset, uint256 assets)
        external
        onlyRole(RESOLVER_ROLE)
        returns (uint256 amountBurned)
    {
        amountBurned = withdrawalRequest.resolveWithdrawalRequest(id, asset, assets, 0);
    }

    function resolveWithdrawalRequest(uint256 id, address[] calldata assets, uint256[] calldata assetAmounts)
        external
        onlyRole(RESOLVER_ROLE)
        returns (uint256[] memory amountsBurned)
    {
        if (assets.length != assetAmounts.length) {
            revert ArrayLengthMismatch(assets.length, assetAmounts.length);
        }

        amountsBurned = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            amountsBurned[i] = withdrawalRequest.resolveWithdrawalRequest(id, assets[i], assetAmounts[i], 0);
        }
    }
}
