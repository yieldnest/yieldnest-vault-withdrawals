// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {BaseScript} from "lib/yieldnest-vault/script/BaseScript.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract DeployWithdrawalRequestViewer is BaseScript {
    WithdrawalRequestViewer public withdrawalRequestViewer;

    /// @notice Returns the deployment symbol used for labels and output JSON.
    /// @return Script deployment symbol.
    function symbol() public pure override returns (string memory) {
        return "withdrawalRequestViewer";
    }

    /// @notice Deploys the stateless withdrawal request viewer and writes deployment metadata.
    function run() public {
        vm.startBroadcast();

        _setup();
        deployer = tx.origin;

        withdrawalRequestViewer = new WithdrawalRequestViewer();

        _verifySetup();
        _saveDeployment();

        vm.stopBroadcast();
    }

    /// @notice Verifies the viewer deployment.
    function _verifySetup() public view {
        if (address(withdrawalRequestViewer).code.length == 0) revert InvalidSetup();
    }

    /// @notice Returns the output JSON path for this deployment.
    /// @return Deployment file path.
    function deploymentFilePath() public view returns (string memory) {
        return _deploymentFilePath();
    }

    function _saveDeployment() internal virtual {
        vm.serializeAddress(symbol(), "viewer", address(withdrawalRequestViewer));
        string memory jsonOutput = vm.serializeAddress(symbol(), "deployer", deployer);

        vm.writeJson(jsonOutput, _deploymentFilePath());
    }
}
