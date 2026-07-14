// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {MainnetContracts as MC} from "lib/yieldnest-vault/script/Contracts.sol";
import {BaseScript} from "lib/yieldnest-vault/script/BaseScript.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract DeployWithdrawalRequest is BaseScript {
    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 10 ether;

    Bag public bagImplementation;
    BeaconProxyFactory public proxyFactoryImplementation;
    BeaconProxyFactory public proxyFactory;
    BaseWithdrawer public requestWithdrawer;
    WithdrawalRequest public requestImplementation;
    WithdrawalRequest public withdrawalRequest;
    WithdrawalRequestViewer public withdrawalRequestViewer;
    ERC1967Proxy public proxyFactoryProxy;
    ERC1967Proxy public proxy;

    address public token;
    address public defaultAdmin;
    address public resolver;
    address public configurationManager;
    address public pauser;
    address public proposer;
    address public executor;
    address public predictedProxy;

    function symbol() public pure override returns (string memory) {
        return "withdrawalRequest-ynETHx";
    }

    function run() public {
        vm.startBroadcast();

        _setup();
        assignDeploymentParameters();
        _verifyDeploymentParams();

        deployer = tx.origin;
        uint256 nonce = vm.getNonce(deployer);
        predictedProxy = vm.computeCreateAddress(deployer, nonce + 6);

        _deployTimelockController();
        defaultAdmin = address(timelock);
        configurationManager = address(timelock);

        bagImplementation = new Bag();
        proxyFactoryImplementation = new BeaconProxyFactory();
        proxyFactoryProxy = new ERC1967Proxy(
            address(proxyFactoryImplementation),
            abi.encodeCall(
                BeaconProxyFactory.initialize, (address(bagImplementation), defaultAdmin, predictedProxy, defaultAdmin)
            )
        );
        proxyFactory = BeaconProxyFactory(address(proxyFactoryProxy));
        requestWithdrawer = new BaseWithdrawer(token, predictedProxy);
        requestImplementation = new WithdrawalRequest();
        proxy = new ERC1967Proxy(
            address(requestImplementation),
            abi.encodeCall(
                WithdrawalRequest.initialize,
                (
                    token,
                    defaultAdmin,
                    resolver,
                    configurationManager,
                    pauser,
                    address(proxyFactory),
                    address(requestWithdrawer),
                    MIN_WITHDRAWAL_AMOUNT
                )
            )
        );
        withdrawalRequest = WithdrawalRequest(address(proxy));
        require(address(withdrawalRequest) == predictedProxy, "unexpected proxy address");

        withdrawalRequestViewer = new WithdrawalRequestViewer();

        _verifySetup();
        _saveDeployment();

        vm.stopBroadcast();
    }

    function assignDeploymentParameters() internal virtual {
        token = MC.YNETHX;
        proposer = actors.ADMIN();
        executor = actors.ADMIN();
        resolver = actors.ADMIN();
        pauser = actors.PAUSER();
    }

    function _verifyDeploymentParams() internal view virtual {
        if (token == address(0)) revert InvalidSetup();
        if (proposer == address(0)) revert InvalidSetup();
        if (executor == address(0)) revert InvalidSetup();
        if (resolver == address(0)) revert InvalidSetup();
        if (pauser == address(0)) revert InvalidSetup();
    }

    function _deployTimelockController() internal virtual {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(minDelay, proposers, executors, address(0));
    }

    function _verifySetup() public view virtual {
        if (address(timelock) == address(0)) revert InvalidSetup();
        if (address(withdrawalRequest) != predictedProxy) revert InvalidSetup();
        if (!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock))) revert InvalidSetup();
        if (timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), proposer)) revert InvalidSetup();
        if (!timelock.hasRole(timelock.PROPOSER_ROLE(), proposer)) revert InvalidSetup();
        if (!timelock.hasRole(timelock.CANCELLER_ROLE(), proposer)) revert InvalidSetup();
        if (!timelock.hasRole(timelock.EXECUTOR_ROLE(), executor)) revert InvalidSetup();
        if (!withdrawalRequest.hasRole(withdrawalRequest.DEFAULT_ADMIN_ROLE(), address(timelock))) {
            revert InvalidSetup();
        }
        if (!withdrawalRequest.hasRole(withdrawalRequest.CONFIGURATION_MANAGER_ROLE(), address(timelock))) {
            revert InvalidSetup();
        }
        if (!withdrawalRequest.hasRole(withdrawalRequest.RESOLVER_ROLE(), resolver)) {
            revert InvalidSetup();
        }
        if (address(withdrawalRequest.withdrawer()) != address(requestWithdrawer)) revert InvalidSetup();
        if (!proxyFactory.hasRole(proxyFactory.DEFAULT_ADMIN_ROLE(), address(timelock))) revert InvalidSetup();
        if (!proxyFactory.hasRole(proxyFactory.IMPLEMENTATION_MANAGER_ROLE(), address(timelock))) {
            revert InvalidSetup();
        }
    }

    function label() public view returns (string memory) {
        return string.concat(symbol(), "-", Strings.toString(block.chainid));
    }

    function deploymentFilePath() public view returns (string memory) {
        return _deploymentFilePath();
    }

    function _saveDeployment() internal virtual {
        vm.serializeAddress(symbol(), "implementation", address(requestImplementation));
        vm.serializeAddress(symbol(), "timelock", address(timelock));
        vm.serializeAddress(symbol(), "bagImplementation", address(bagImplementation));
        vm.serializeAddress(symbol(), "proxyFactoryImplementation", address(proxyFactoryImplementation));
        vm.serializeAddress(symbol(), "proxyFactory", address(proxyFactory));
        vm.serializeAddress(symbol(), "proxyFactoryProxy", address(proxyFactoryProxy));
        vm.serializeAddress(symbol(), "beacon", proxyFactory.beacon());
        vm.serializeAddress(symbol(), "withdrawer", address(requestWithdrawer));
        vm.serializeAddress(symbol(), "proxy", address(proxy));
        vm.serializeAddress(symbol(), "predictedProxy", predictedProxy);
        vm.serializeAddress(symbol(), "withdrawalRequest", address(withdrawalRequest));
        vm.serializeAddress(symbol(), "viewer", address(withdrawalRequestViewer));
        vm.serializeAddress(symbol(), "token", token);
        vm.serializeUint(symbol(), "minWithdrawalAmount", MIN_WITHDRAWAL_AMOUNT);
        vm.serializeUint(symbol(), "timelockMinDelay", minDelay);
        vm.serializeAddress(symbol(), "defaultAdmin", defaultAdmin);
        vm.serializeAddress(symbol(), "resolver", resolver);
        vm.serializeAddress(symbol(), "configurationManager", configurationManager);
        vm.serializeAddress(symbol(), "pauser", pauser);
        vm.serializeAddress(symbol(), "proposer", proposer);
        vm.serializeAddress(symbol(), "executor", executor);

        string memory jsonOutput = vm.serializeAddress(symbol(), "deployer", deployer);

        vm.writeJson(jsonOutput, _deploymentFilePath());
    }
}
