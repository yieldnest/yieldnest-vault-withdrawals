// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";

contract DeployMinAmountRequestPolicy is Script {
    /**
     * @notice Deploys a request policy requiring at least 100e18 yn-token share units.
     * @return policy The deployed policy; does not update any withdrawal request manager.
     */
    function run() external returns (MinAmountRequestPolicy policy) {
        vm.startBroadcast();
        policy = new MinAmountRequestPolicy(100e18);
        vm.stopBroadcast();

        console2.log("MinAmountRequestPolicy:", address(policy));
    }
}
