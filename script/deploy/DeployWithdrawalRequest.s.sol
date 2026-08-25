// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {MainnetContracts as MC} from "lib/yieldnest-vault/script/Contracts.sol";
import {DeployWithdrawalRequestBase} from "script/deploy/DeployWithdrawalRequestBase.s.sol";

contract DeployWithdrawalRequest is DeployWithdrawalRequestBase {
    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 0.0001 ether;

    constructor() DeployWithdrawalRequestBase("withdrawalRequest-ynETHx", MC.YNETHX, MIN_WITHDRAWAL_AMOUNT) {}
}
