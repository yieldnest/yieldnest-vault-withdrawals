// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {IWithdrawalRequest} from "src/interface/IWithdrawalRequest.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

/**
 * @notice Deploys and configures a withdrawal request system in one constructor transaction.
 * @dev Implementation contracts must already exist. This contract receives no administrative roles.
 */
contract WithdrawalRequestDeployer {
    struct Implementations {
        address withdrawalRequest;
        address withdrawer;
        address bagFactory;
        address bag;
    }

    struct DeploymentParams {
        Implementations implementations;
        address token;
        address proposer;
        address executor;
        address resolver;
        address pauser;
        string name;
        string symbol;
        uint256 minWithdrawalAmount;
        uint256 maxDataLength;
    }

    uint256 public constant MIN_DELAY = 1 days;

    TimelockController public immutable timelock;
    WithdrawalRequest public immutable withdrawalRequest;
    BeaconProxyFactory public immutable bagFactory;
    BaseWithdrawer public immutable withdrawer;
    MinAmountRequestPolicy public immutable requestPolicy;
    WithdrawalRequestViewer public immutable viewer;

    error InvalidDeploymentParams();
    error InvalidImplementation(address implementation);

    /**
     * @notice Creates the timelock, proxies, request policy, and viewer and initializes all bindings.
     * @param params Existing implementations and configuration for the new system.
     */
    constructor(DeploymentParams memory params) {
        if (
            params.token.code.length == 0 || params.proposer == address(0) || params.executor == address(0)
                || params.resolver == address(0) || params.pauser == address(0) || params.minWithdrawalAmount == 0
        ) revert InvalidDeploymentParams();
        _validateImplementation(params.implementations.withdrawalRequest);
        _validateImplementation(params.implementations.withdrawer);
        _validateImplementation(params.implementations.bagFactory);
        _validateImplementation(params.implementations.bag);

        address[] memory proposers = new address[](1);
        proposers[0] = params.proposer;
        address[] memory executors = new address[](1);
        executors[0] = params.executor;
        TimelockController admin = new TimelockController(MIN_DELAY, proposers, executors, address(0));
        timelock = admin;

        // Initialize below, after its dependent modules exist, within this same constructor transaction.
        WithdrawalRequest request = WithdrawalRequest(
            address(new TransparentUpgradeableProxy(params.implementations.withdrawalRequest, address(admin), ""))
        );
        withdrawalRequest = request;
        BeaconProxyFactory factory = BeaconProxyFactory(
            address(
                new TransparentUpgradeableProxy(
                    params.implementations.bagFactory,
                    address(admin),
                    abi.encodeCall(
                        BeaconProxyFactory.initialize,
                        (params.implementations.bag, address(admin), address(request), address(admin))
                    )
                )
            )
        );
        bagFactory = factory;
        BaseWithdrawer adapter = BaseWithdrawer(
            address(
                new TransparentUpgradeableProxy(
                    params.implementations.withdrawer,
                    address(admin),
                    abi.encodeCall(BaseWithdrawer.initialize, (params.token, address(request)))
                )
            )
        );
        withdrawer = adapter;
        MinAmountRequestPolicy policy = new MinAmountRequestPolicy(params.minWithdrawalAmount);
        requestPolicy = policy;
        request.initialize(
            IWithdrawalRequest.InitializeParams({
                token: params.token,
                name: params.name,
                symbol: params.symbol,
                defaultAdmin: address(admin),
                resolver: params.resolver,
                configurationManager: address(admin),
                pauser: params.pauser,
                bagFactory: address(factory),
                withdrawer: address(adapter),
                requestPolicy: address(policy),
                maxDataLength: params.maxDataLength
            })
        );
        viewer = new WithdrawalRequestViewer();
    }

    function _validateImplementation(address implementation) internal view {
        if (implementation.code.length == 0) revert InvalidImplementation(implementation);
    }
}
