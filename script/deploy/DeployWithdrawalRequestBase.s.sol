// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {BaseScript} from "lib/yieldnest-vault/script/BaseScript.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

abstract contract DeployWithdrawalRequestBase is BaseScript {
    uint256 public constant MAX_DATA_LENGTH = 1024;

    string private _deploymentSymbol;
    address private _deploymentToken;
    uint256 private _minWithdrawalAmount;

    Bag public bagImplementation;
    BeaconProxyFactory public bagFactoryImplementation;
    BeaconProxyFactory public bagFactory;
    BaseWithdrawer public requestWithdrawerImplementation;
    BaseWithdrawer public requestWithdrawer;
    MinAmountRequestPolicy public requestPolicy;
    WithdrawalRequest public requestImplementation;
    WithdrawalRequest public withdrawalRequest;
    WithdrawalRequestViewer public withdrawalRequestViewer;
    TransparentUpgradeableProxy public bagFactoryProxy;
    TransparentUpgradeableProxy public requestWithdrawerProxy;
    TransparentUpgradeableProxy public proxy;

    address public token;
    address public defaultAdmin;
    address public resolver;
    address public configurationManager;
    address public pauser;
    address public proposer;
    address public executor;
    address public predictedProxy;

    constructor(string memory deploymentSymbol_, address deploymentToken_, uint256 minWithdrawalAmount_) {
        _deploymentSymbol = deploymentSymbol_;
        _deploymentToken = deploymentToken_;
        _minWithdrawalAmount = minWithdrawalAmount_;
    }

    /// @notice Returns the deployment symbol used for labels and output JSON.
    /// @return Script deployment symbol.
    function symbol() public view override returns (string memory) {
        return _deploymentSymbol;
    }

    /// @notice Returns the vault token deployed against by this script.
    /// @return Vault token address.
    function deploymentToken() public view returns (address) {
        return _deploymentToken;
    }

    /// @notice Returns the minimum request amount configured in the request policy.
    /// @return Minimum withdrawal request amount in vault token units.
    function minWithdrawalAmount() public view returns (uint256) {
        return _minWithdrawalAmount;
    }

    /// @notice Deploys the withdrawal request system and writes deployment metadata.
    function run() public {
        vm.startBroadcast();

        _setup();
        assignDeploymentParameters();
        _verifyDeploymentParams();

        deployer = tx.origin;
        uint256 nonce = vm.getNonce(deployer);
        predictedProxy = vm.computeCreateAddress(deployer, nonce + 8);

        _deployTimelockController();
        defaultAdmin = address(timelock);
        configurationManager = address(timelock);

        bagImplementation = new Bag();
        bagFactoryImplementation = new BeaconProxyFactory();
        bagFactoryProxy = new TransparentUpgradeableProxy(
            address(bagFactoryImplementation),
            defaultAdmin,
            abi.encodeCall(
                BeaconProxyFactory.initialize, (address(bagImplementation), defaultAdmin, predictedProxy, defaultAdmin)
            )
        );
        bagFactory = BeaconProxyFactory(address(bagFactoryProxy));
        requestWithdrawerImplementation = new BaseWithdrawer();
        requestWithdrawerProxy = new TransparentUpgradeableProxy(
            address(requestWithdrawerImplementation),
            defaultAdmin,
            abi.encodeCall(BaseWithdrawer.initialize, (token, predictedProxy))
        );
        requestWithdrawer = BaseWithdrawer(address(requestWithdrawerProxy));
        requestPolicy = new MinAmountRequestPolicy(minWithdrawalAmount());
        requestImplementation = new WithdrawalRequest();
        proxy = new TransparentUpgradeableProxy(
            address(requestImplementation),
            defaultAdmin,
            abi.encodeCall(
                WithdrawalRequest.initialize,
                (
                    token,
                    defaultAdmin,
                    resolver,
                    configurationManager,
                    pauser,
                    address(bagFactory),
                    address(requestWithdrawer),
                    address(requestPolicy),
                    MAX_DATA_LENGTH
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
        token = deploymentToken();
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
        if (minWithdrawalAmount() == 0) revert InvalidSetup();
    }

    function _deployTimelockController() internal virtual {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(minDelay, proposers, executors, address(0));
    }

    /// @notice Verifies deployed contracts, roles, and module wiring.
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
        if (address(withdrawalRequest.requestPolicy()) != address(requestPolicy)) revert InvalidSetup();
        if (requestPolicy.minWithdrawalAmount() != minWithdrawalAmount()) revert InvalidSetup();
        if (withdrawalRequest.maxDataLength() != MAX_DATA_LENGTH) revert InvalidSetup();
        if (!bagFactory.hasRole(bagFactory.DEFAULT_ADMIN_ROLE(), address(timelock))) revert InvalidSetup();
        if (!bagFactory.hasRole(bagFactory.IMPLEMENTATION_MANAGER_ROLE(), address(timelock))) {
            revert InvalidSetup();
        }
    }

    /// @notice Returns the deployment label including chain id.
    /// @return Deployment label.
    function label() public view returns (string memory) {
        return string.concat(symbol(), "-", Strings.toString(block.chainid));
    }

    /// @notice Returns the output JSON path for this deployment.
    /// @return Deployment file path.
    function deploymentFilePath() public view returns (string memory) {
        return _deploymentFilePath();
    }

    function _saveDeployment() internal virtual {
        vm.serializeAddress(symbol(), "implementation", address(requestImplementation));
        vm.serializeAddress(symbol(), "timelock", address(timelock));
        vm.serializeAddress(symbol(), "bagImplementation", address(bagImplementation));
        vm.serializeAddress(symbol(), "bagFactoryImplementation", address(bagFactoryImplementation));
        vm.serializeAddress(symbol(), "bagFactory", address(bagFactory));
        vm.serializeAddress(symbol(), "bagFactoryProxy", address(bagFactoryProxy));
        vm.serializeAddress(symbol(), "beacon", bagFactory.beacon());
        vm.serializeAddress(symbol(), "withdrawerImplementation", address(requestWithdrawerImplementation));
        vm.serializeAddress(symbol(), "withdrawer", address(requestWithdrawer));
        vm.serializeAddress(symbol(), "withdrawerProxy", address(requestWithdrawerProxy));
        vm.serializeAddress(symbol(), "requestPolicy", address(requestPolicy));
        vm.serializeAddress(symbol(), "proxy", address(proxy));
        vm.serializeAddress(symbol(), "predictedProxy", predictedProxy);
        vm.serializeAddress(symbol(), "withdrawalRequest", address(withdrawalRequest));
        vm.serializeAddress(symbol(), "viewer", address(withdrawalRequestViewer));
        vm.serializeAddress(symbol(), "token", token);
        vm.serializeUint(symbol(), "minWithdrawalAmount", minWithdrawalAmount());
        vm.serializeUint(symbol(), "maxDataLength", MAX_DATA_LENGTH);
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
