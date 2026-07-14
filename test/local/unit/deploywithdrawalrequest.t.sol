// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {RequestRateProvider} from "src/RequestRateProvider.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {DeployWithdrawalRequest} from "script/deploy/DeployWithdrawalRequest.s.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract DeployWithdrawalRequestTest is Test {
    function testRunDeploysAndRecordsViewer() public {
        DeployWithdrawalRequest deployScript = new DeployWithdrawalRequest();

        deployScript.run();

        WithdrawalRequestViewer viewer = deployScript.withdrawalRequestViewer();
        TimelockController timelock = deployScript.timelock();
        WithdrawalRequest manager = deployScript.withdrawalRequest();
        BeaconProxyFactory proxyFactory = deployScript.proxyFactory();
        RequestRateProvider redemptionRateProvider = deployScript.redemptionRateProvider();
        assertGt(address(viewer).code.length, 0);
        assertGt(address(redemptionRateProvider).code.length, 0);
        assertGt(address(timelock).code.length, 0);
        assertEq(timelock.getMinDelay(), deployScript.minDelay());
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployScript.executor()));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(manager.hasRole(manager.CONFIGURATION_MANAGER_ROLE(), address(timelock)));
        assertTrue(manager.hasRole(manager.RESOLVER_ROLE(), deployScript.resolver()));
        assertEq(address(manager.redemptionRateProvider()), address(redemptionRateProvider));
        assertEq(manager.surplusCollector(), deployScript.surplusCollector());
        assertTrue(proxyFactory.hasRole(proxyFactory.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(proxyFactory.hasRole(proxyFactory.IMPLEMENTATION_MANAGER_ROLE(), address(timelock)));

        string memory deploymentFilePath =
            string.concat(vm.projectRoot(), "/deployments/", deployScript.label(), ".json");
        string memory deploymentJson = vm.readFile(deploymentFilePath);

        assertEq(vm.parseJsonAddress(deploymentJson, ".timelock"), address(timelock));
        assertEq(vm.parseJsonAddress(deploymentJson, ".viewer"), address(viewer));
        assertEq(vm.parseJsonAddress(deploymentJson, ".withdrawalRequest"), address(manager));
        assertEq(vm.parseJsonAddress(deploymentJson, ".redemptionRateProvider"), address(redemptionRateProvider));
        assertEq(vm.parseJsonAddress(deploymentJson, ".defaultAdmin"), address(timelock));
        assertEq(vm.parseJsonAddress(deploymentJson, ".resolver"), deployScript.resolver());
        assertEq(vm.parseJsonAddress(deploymentJson, ".surplusCollector"), deployScript.surplusCollector());
        assertEq(vm.parseJsonAddress(deploymentJson, ".configurationManager"), address(timelock));
        assertEq(vm.parseJsonUint(deploymentJson, ".minWithdrawalAmount"), deployScript.MIN_WITHDRAWAL_AMOUNT());
        assertEq(vm.parseJsonUint(deploymentJson, ".timelockMinDelay"), deployScript.minDelay());

        vm.removeFile(deploymentFilePath);
    }
}
