// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IBeaconProxyFactory {
    function create(bytes calldata initData) external returns (address proxy);
}
