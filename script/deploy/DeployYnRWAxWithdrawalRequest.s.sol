// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {DeployWithdrawalRequestBase} from "script/deploy/DeployWithdrawalRequestBase.s.sol";

contract DeployYnRWAxWithdrawalRequest is DeployWithdrawalRequestBase {
    address public constant YNRWAX = 0x01Ba69727E2860b37bc1a2bd56999c1aFb4C15D8;
    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 10_000;

    constructor() DeployWithdrawalRequestBase("withdrawalRequest-ynRWAx", YNRWAX, MIN_WITHDRAWAL_AMOUNT) {}
}
