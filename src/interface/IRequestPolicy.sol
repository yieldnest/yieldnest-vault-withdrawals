// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IRequestPolicy {
    function validateRequest(address caller, address receiver, uint256 amount) external view;
}
