// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IAuth {
    /// @notice Returns the owner of a request id.
    /// @param id Request id to query.
    /// @return Owner of the request NFT.
    function ownerOf(uint256 id) external view returns (address);
}
