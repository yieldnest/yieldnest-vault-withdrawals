// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IRequestPolicy {
    /// @notice Validates whether a withdrawal request may be created.
    /// @param caller Account creating the request.
    /// @param receiver Account that will receive the request NFT.
    /// @param amount Amount of yn-token shares to lock.
    /// @param data Arbitrary request metadata supplied at creation.
    function validateRequest(address caller, address receiver, uint256 amount, bytes calldata data) external view;

    /// @notice Returns the minimum yn-token share amount required by the policy.
    /// @return Minimum withdrawal amount in yn-token shares.
    function minWithdrawalAmount() external view returns (uint256);
}
