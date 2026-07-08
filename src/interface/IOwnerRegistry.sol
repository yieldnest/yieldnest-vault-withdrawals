// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IOwnerRegistry {
    function ownerOf(uint256 id) external view returns (address);
}
