// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DeployWithdrawalRequestManager} from "script/deploy/DeployWithdrawalRequestManager.s.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract DeployWithdrawalRequestManagerTest is Test {
    function testRunDeploysAndRecordsViewer() public {
        DeployWithdrawalRequestManager deployScript = new DeployWithdrawalRequestManager();

        deployScript.run();

        WithdrawalRequestViewer viewer = deployScript.viewer();
        assertGt(address(viewer).code.length, 0);

        string memory deploymentFilePath =
            string.concat(vm.projectRoot(), "/deployments/", deployScript.label(), ".json");
        string memory deploymentJson = vm.readFile(deploymentFilePath);

        assertEq(vm.parseJsonAddress(deploymentJson, ".viewer"), address(viewer));
        assertEq(
            vm.parseJsonAddress(deploymentJson, ".withdrawalRequestManager"),
            address(deployScript.withdrawalRequestManager())
        );

        vm.removeFile(deploymentFilePath);
    }
}
