// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IFactory {
    /// @notice Creates a new proxy or contract initialized with arbitrary call data.
    /// @param initData Initialization call data for the created contract.
    /// @return proxy Created contract address.
    function create(bytes calldata initData) external returns (address proxy);
}
