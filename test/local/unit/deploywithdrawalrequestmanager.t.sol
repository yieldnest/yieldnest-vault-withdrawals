// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {WithdrawalRequestManager} from "src/WithdrawalRequestManager.sol";
import {DeployWithdrawalRequestManager} from "script/deploy/DeployWithdrawalRequestManager.s.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract DeployWithdrawalRequestManagerTest is Test {
    function testRunDeploysAndRecordsViewer() public {
        DeployWithdrawalRequestManager deployScript = new DeployWithdrawalRequestManager();

        deployScript.run();

        WithdrawalRequestViewer viewer = deployScript.withdrawalRequestViewer();
        TimelockController timelock = deployScript.timelock();
        WithdrawalRequestManager manager = deployScript.withdrawalRequestManager();
        BeaconProxyFactory beaconFactory = deployScript.beaconFactory();
        assertGt(address(viewer).code.length, 0);
        assertGt(address(timelock).code.length, 0);
        assertEq(timelock.getMinDelay(), deployScript.minDelay());
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployScript.executor()));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(manager.hasRole(manager.CONFIGURATION_MANAGER_ROLE(), address(timelock)));
        assertTrue(beaconFactory.hasRole(beaconFactory.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(beaconFactory.hasRole(beaconFactory.IMPLEMENTATION_MANAGER_ROLE(), address(timelock)));

        string memory deploymentFilePath =
            string.concat(vm.projectRoot(), "/deployments/", deployScript.label(), ".json");
        string memory deploymentJson = vm.readFile(deploymentFilePath);

        assertEq(vm.parseJsonAddress(deploymentJson, ".timelock"), address(timelock));
        assertEq(vm.parseJsonAddress(deploymentJson, ".viewer"), address(viewer));
        assertEq(vm.parseJsonAddress(deploymentJson, ".withdrawalRequestManager"), address(manager));
        assertEq(vm.parseJsonAddress(deploymentJson, ".defaultAdmin"), address(timelock));
        assertEq(vm.parseJsonAddress(deploymentJson, ".configurationManager"), address(timelock));
        assertEq(vm.parseJsonUint(deploymentJson, ".timelockMinDelay"), deployScript.minDelay());

        vm.removeFile(deploymentFilePath);
    }
}
