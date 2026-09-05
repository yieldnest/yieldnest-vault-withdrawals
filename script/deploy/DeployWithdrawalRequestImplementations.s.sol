// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {BaseScript} from "lib/yieldnest-vault/script/BaseScript.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";

contract DeployWithdrawalRequestImplementations is BaseScript {
    bytes32 internal constant WITHDRAWAL_REQUEST =
        keccak256("yieldnest.yieldnest-vault-withdrawals.contracts.src.WithdrawalRequest");
    bytes32 internal constant WITHDRAWER =
        keccak256("yieldnest.yieldnest-vault-withdrawals.contracts.src.withdrawers.BaseWithdrawer");
    bytes32 internal constant BAG_FACTORY =
        keccak256("yieldnest.yieldnest-vault-withdrawals.contracts.src.BeaconProxyFactory");
    bytes32 internal constant BAG = keccak256("yieldnest.yieldnest-vault-withdrawals.contracts.src.Bag");

    WithdrawalRequest public withdrawalRequestImplementation;
    BaseWithdrawer public requestWithdrawerImplementation;
    BeaconProxyFactory public bagFactoryImplementation;
    Bag public bagImplementation;

    /// @notice Returns the deployment symbol used for labels and output JSON.
    /// @return Script deployment symbol.
    function symbol() public pure override returns (string memory) {
        return "withdrawalRequestImplementations";
    }

    /// @notice Deploys the withdrawal request implementation contracts and writes deployment metadata.
    function run() public {
        vm.startBroadcast();

        _setup();
        deployer = tx.origin;

        withdrawalRequestImplementation = new WithdrawalRequest();
        requestWithdrawerImplementation = new BaseWithdrawer();
        bagFactoryImplementation = new BeaconProxyFactory();
        bagImplementation = new Bag();

        _verifySetup();
        _saveDeployment();

        vm.stopBroadcast();
    }

    /// @notice Verifies the implementation deployments.
    function _verifySetup() public view {
        if (address(withdrawalRequestImplementation).code.length == 0) revert InvalidSetup();
        if (address(requestWithdrawerImplementation).code.length == 0) revert InvalidSetup();
        if (address(bagFactoryImplementation).code.length == 0) revert InvalidSetup();
        if (address(bagImplementation).code.length == 0) revert InvalidSetup();
    }

    /// @notice Returns the output JSON path for this deployment.
    /// @return Deployment file path.
    function deploymentFilePath() public view returns (string memory) {
        return _deploymentFilePath();
    }

    function _saveDeployment() internal virtual {
        vm.serializeBytes32(symbol(), "WITHDRAWAL_REQUEST", WITHDRAWAL_REQUEST);
        vm.serializeBytes32(symbol(), "WITHDRAWER", WITHDRAWER);
        vm.serializeBytes32(symbol(), "BAG_FACTORY", BAG_FACTORY);
        vm.serializeBytes32(symbol(), "BAG", BAG);

        vm.serializeAddress(symbol(), vm.toString(WITHDRAWAL_REQUEST), address(withdrawalRequestImplementation));
        vm.serializeAddress(symbol(), vm.toString(WITHDRAWER), address(requestWithdrawerImplementation));
        vm.serializeAddress(symbol(), vm.toString(BAG_FACTORY), address(bagFactoryImplementation));
        vm.serializeAddress(symbol(), vm.toString(BAG), address(bagImplementation));

        vm.serializeAddress(symbol(), "withdrawalRequestImplementation", address(withdrawalRequestImplementation));
        vm.serializeAddress(symbol(), "withdrawerImplementation", address(requestWithdrawerImplementation));
        vm.serializeAddress(symbol(), "bagFactoryImplementation", address(bagFactoryImplementation));
        vm.serializeAddress(symbol(), "bagImplementation", address(bagImplementation));
        string memory jsonOutput = vm.serializeAddress(symbol(), "deployer", deployer);

        vm.writeJson(jsonOutput, _deploymentFilePath());
    }
}
