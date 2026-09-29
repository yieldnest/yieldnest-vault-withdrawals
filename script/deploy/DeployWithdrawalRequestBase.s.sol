// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {Script} from "lib/forge-std/src/Script.sol";
import {IActors, MainnetActors} from "lib/yieldnest-vault/script/Actors.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {WithdrawalRequestDeployer} from "script/WithdrawalRequestDeployer.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

abstract contract DeployWithdrawalRequestBase is Script {
    uint256 public constant minDelay = 1 days;
    IActors public actors;
    address public deployer;
    TimelockController public timelock;

    error InvalidSetup();

    uint256 public constant MAX_DATA_LENGTH = 1024;
    string public constant REQUEST_NFT_NAME = "MAX Vault Withdrawal Request";
    string public constant REQUEST_NFT_SYMBOL = "ynWREQ";

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
    WithdrawalRequestDeployer public systemDeployer;

    address public token;
    address public defaultAdmin;
    address public resolver;
    address public configurationManager;
    address public pauser;
    address public proposer;
    address public executor;

    constructor(string memory deploymentSymbol_, address deploymentToken_, uint256 minWithdrawalAmount_) {
        _deploymentSymbol = deploymentSymbol_;
        _deploymentToken = deploymentToken_;
        _minWithdrawalAmount = minWithdrawalAmount_;
    }

    /// @notice Returns the deployment symbol used for labels and output JSON.
    /// @return Script deployment symbol.
    function symbol() public view returns (string memory) {
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
        _setup();
        assignDeploymentParameters();
        _verifyDeploymentParams();
        WithdrawalRequestDeployer.Implementations memory implementations = _loadImplementations();
        bagImplementation = Bag(payable(implementations.bag));
        bagFactoryImplementation = BeaconProxyFactory(implementations.bagFactory);
        requestWithdrawerImplementation = BaseWithdrawer(implementations.withdrawer);
        requestImplementation = WithdrawalRequest(implementations.withdrawalRequest);

        deployer = tx.origin;
        vm.startBroadcast();
        systemDeployer = new WithdrawalRequestDeployer();
        systemDeployer.deploy(
            WithdrawalRequestDeployer.DeploymentParams({
                implementations: implementations,
                token: token,
                proposer: proposer,
                executor: executor,
                resolver: resolver,
                pauser: pauser,
                name: REQUEST_NFT_NAME,
                symbol: REQUEST_NFT_SYMBOL,
                minWithdrawalAmount: minWithdrawalAmount(),
                maxDataLength: MAX_DATA_LENGTH
            })
        );
        vm.stopBroadcast();

        timelock = systemDeployer.timelock();
        defaultAdmin = address(timelock);
        configurationManager = address(timelock);
        bagFactory = systemDeployer.bagFactory();
        bagFactoryProxy = TransparentUpgradeableProxy(payable(address(bagFactory)));
        requestWithdrawer = systemDeployer.withdrawer();
        requestWithdrawerProxy = TransparentUpgradeableProxy(payable(address(requestWithdrawer)));
        requestPolicy = systemDeployer.requestPolicy();
        withdrawalRequest = systemDeployer.withdrawalRequest();
        proxy = TransparentUpgradeableProxy(payable(address(withdrawalRequest)));
        withdrawalRequestViewer = systemDeployer.viewer();

        _verifySetup();
        _saveDeployment();
    }

    function _loadImplementations() internal virtual returns (WithdrawalRequestDeployer.Implementations memory) {
        string memory json = vm.readFile(_implementationsFilePath());
        return WithdrawalRequestDeployer.Implementations({
            withdrawalRequest: vm.parseJsonAddress(json, ".withdrawalRequestImplementation"),
            withdrawer: vm.parseJsonAddress(json, ".withdrawerImplementation"),
            bagFactory: vm.parseJsonAddress(json, ".bagFactoryImplementation"),
            bag: vm.parseJsonAddress(json, ".bagImplementation")
        });
    }

    function _implementationsFilePath() internal view virtual returns (string memory) {
        return string.concat(
            vm.projectRoot(), "/deployments/withdrawalRequestImplementations-", Strings.toString(block.chainid), ".json"
        );
    }

    function assignDeploymentParameters() internal virtual {
        token = deploymentToken();
        proposer = actors.ADMIN();
        executor = actors.ADMIN();
        resolver = actors.ADMIN();
        pauser = actors.PAUSER();
    }

    function _setup() internal virtual {
        actors = new MainnetActors();
    }

    function _deploymentFilePath() internal view virtual returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", label(), ".json");
    }

    function _proxyAdmin(address proxyAddress) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxyAddress, ERC1967Utils.ADMIN_SLOT))));
    }

    function _verifyDeploymentParams() internal view virtual {
        if (token == address(0)) revert InvalidSetup();
        if (proposer == address(0)) revert InvalidSetup();
        if (executor == address(0)) revert InvalidSetup();
        if (resolver == address(0)) revert InvalidSetup();
        if (pauser == address(0)) revert InvalidSetup();
        if (minWithdrawalAmount() == 0) revert InvalidSetup();
    }

    /// @notice Verifies deployed contracts, roles, and module wiring.
    function _verifySetup() public view virtual {
        if (address(timelock) == address(0)) revert InvalidSetup();
        if (ProxyAdmin(_proxyAdmin(address(proxy))).owner() != address(timelock)) revert InvalidSetup();
        if (ProxyAdmin(_proxyAdmin(address(bagFactoryProxy))).owner() != address(timelock)) revert InvalidSetup();
        if (ProxyAdmin(_proxyAdmin(address(requestWithdrawerProxy))).owner() != address(timelock)) {
            revert InvalidSetup();
        }
        if (address(withdrawalRequest) != address(systemDeployer.withdrawalRequest())) revert InvalidSetup();
        if (timelock.getMinDelay() != minDelay) revert InvalidSetup();
        if (address(requestWithdrawer.token()) != token) revert InvalidSetup();
        if (requestWithdrawer.withdrawalRequest() != address(withdrawalRequest)) revert InvalidSetup();
        if (!bagFactory.hasRole(bagFactory.CREATOR_ROLE(), address(withdrawalRequest))) revert InvalidSetup();
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
        vm.serializeAddress(symbol(), "bagFactoryProxyAdmin", _proxyAdmin(address(bagFactoryProxy)));
        vm.serializeAddress(symbol(), "beacon", bagFactory.beacon());
        vm.serializeAddress(symbol(), "withdrawerImplementation", address(requestWithdrawerImplementation));
        vm.serializeAddress(symbol(), "withdrawer", address(requestWithdrawer));
        vm.serializeAddress(symbol(), "withdrawerProxy", address(requestWithdrawerProxy));
        vm.serializeAddress(symbol(), "withdrawerProxyAdmin", _proxyAdmin(address(requestWithdrawerProxy)));
        vm.serializeAddress(symbol(), "requestPolicy", address(requestPolicy));
        vm.serializeAddress(symbol(), "proxy", address(proxy));
        vm.serializeAddress(symbol(), "proxyAdmin", _proxyAdmin(address(proxy)));
        vm.serializeAddress(symbol(), "systemDeployer", address(systemDeployer));
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
