// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IRequestPolicy} from "src/interface/IRequestPolicy.sol";

/// @title MinAmountRequestPolicy
/// @notice Request policy that requires each withdrawal request to lock at least a configured share amount.
contract MinAmountRequestPolicy is IRequestPolicy {
    uint256 public immutable minWithdrawalAmount;

    error AmountBelowMinimum(uint256 amount, uint256 minWithdrawalAmount);

    /// @notice Deploys a policy with a fixed minimum withdrawal amount.
    /// @param minWithdrawalAmount_ Minimum yn-token share amount required for each request.
    constructor(uint256 minWithdrawalAmount_) {
        minWithdrawalAmount = minWithdrawalAmount_;
    }

    /// @notice Reverts if the requested amount is below the configured minimum.
    /// @param amount Amount of yn-token shares the request would lock.
    function validateRequest(address, address, uint256 amount, bytes calldata) external view {
        if (amount < minWithdrawalAmount) revert AmountBelowMinimum(amount, minWithdrawalAmount);
    }
}
