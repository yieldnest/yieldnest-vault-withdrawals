// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {MainnetContracts as MC} from "lib/yieldnest-vault/script/Contracts.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {DeployWithdrawalRequest} from "script/deploy/DeployWithdrawalRequest.s.sol";
import {DeployYnRWAxWithdrawalRequest} from "script/deploy/DeployYnRWAxWithdrawalRequest.s.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

error InvalidSetup();

contract DeploymentTokenMock is ERC20 {
    constructor() ERC20("Token", "TKN") {}
}

contract DeployWithdrawalRequestHarness is DeployWithdrawalRequest {
    function _deploymentFilePath() internal view override returns (string memory) {
        return string.concat(
            vm.projectRoot(),
            "/deployments/",
            symbol(),
            "-",
            vm.toString(block.chainid),
            "-",
            vm.toString(address(this)),
            ".json"
        );
    }

    function setDeploymentParams(
        address token_,
        address proposer_,
        address executor_,
        address resolver_,
        address pauser_
    ) external {
        token = token_;
        proposer = proposer_;
        executor = executor_;
        resolver = resolver_;
        pauser = pauser_;
    }

    function setPredictedProxy(address predictedProxy_) external {
        predictedProxy = predictedProxy_;
    }

    function setTimelock(TimelockController timelock_) external {
        timelock = timelock_;
    }

    function setRequestWithdrawer(BaseWithdrawer requestWithdrawer_) external {
        requestWithdrawer = requestWithdrawer_;
    }

    function setRequestPolicy(MinAmountRequestPolicy requestPolicy_) external {
        requestPolicy = requestPolicy_;
    }

    function verifyDeploymentParams() external view {
        _verifyDeploymentParams();
    }
}

contract DeployYnRWAxWithdrawalRequestHarness is DeployYnRWAxWithdrawalRequest {
    function _deploymentFilePath() internal view override returns (string memory) {
        return string.concat(
            vm.projectRoot(),
            "/deployments/",
            symbol(),
            "-",
            vm.toString(block.chainid),
            "-",
            vm.toString(address(this)),
            ".json"
        );
    }
}

contract DeployWithdrawalRequestTest is Test {
    function _etchDeploymentToken(address tokenAddress) internal {
        DeploymentTokenMock token = new DeploymentTokenMock();
        vm.etch(tokenAddress, address(token).code);
    }

    function _deployScript() internal returns (DeployWithdrawalRequestHarness deployScript) {
        _etchDeploymentToken(MC.YNETHX);

        deployScript = new DeployWithdrawalRequestHarness();
        deployScript.run();
    }

    function testRunDeploysAndRecordsViewer() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        _etchDeploymentToken(MC.YNETHX);
        assertEq(deployScript.symbol(), "withdrawalRequest-ynETHx");
        assertEq(deployScript.deploymentToken(), MC.YNETHX);
        assertEq(deployScript.minWithdrawalAmount(), deployScript.MIN_WITHDRAWAL_AMOUNT());
        assertEq(deployScript.label(), string.concat(deployScript.symbol(), "-", vm.toString(block.chainid)));
        assertTrue(bytes(deployScript.deploymentFilePath()).length != 0);

        deployScript.run();
        deployScript._verifySetup();

        WithdrawalRequestViewer viewer = deployScript.withdrawalRequestViewer();
        TimelockController timelock = deployScript.timelock();
        WithdrawalRequest manager = deployScript.withdrawalRequest();
        BeaconProxyFactory bagFactory = deployScript.bagFactory();
        BaseWithdrawer withdrawer = deployScript.requestWithdrawer();
        BaseWithdrawer withdrawerImplementation = deployScript.requestWithdrawerImplementation();
        MinAmountRequestPolicy requestPolicy = deployScript.requestPolicy();
        assertGt(address(viewer).code.length, 0);
        assertGt(address(withdrawer).code.length, 0);
        assertGt(address(withdrawerImplementation).code.length, 0);
        assertGt(address(requestPolicy).code.length, 0);
        assertGt(address(timelock).code.length, 0);
        assertEq(address(withdrawer.token()), MC.YNETHX);
        assertEq(withdrawer.withdrawalRequest(), address(manager));
        assertEq(timelock.getMinDelay(), deployScript.minDelay());
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), deployScript.proposer()));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployScript.executor()));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(manager.hasRole(manager.CONFIGURATION_MANAGER_ROLE(), address(timelock)));
        assertTrue(manager.hasRole(manager.RESOLVER_ROLE(), deployScript.resolver()));
        assertEq(address(manager.withdrawer()), address(withdrawer));
        assertEq(address(manager.requestPolicy()), address(requestPolicy));
        assertEq(requestPolicy.minWithdrawalAmount(), deployScript.minWithdrawalAmount());
        assertEq(manager.maxDataLength(), deployScript.MAX_DATA_LENGTH());
        assertTrue(bagFactory.hasRole(bagFactory.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(bagFactory.hasRole(bagFactory.IMPLEMENTATION_MANAGER_ROLE(), address(timelock)));

        string memory deploymentFilePath = deployScript.deploymentFilePath();
        string memory deploymentJson = vm.readFile(deploymentFilePath);

        assertEq(vm.parseJsonAddress(deploymentJson, ".timelock"), address(timelock));
        assertEq(vm.parseJsonAddress(deploymentJson, ".viewer"), address(viewer));
        assertEq(vm.parseJsonAddress(deploymentJson, ".bagFactory"), address(bagFactory));
        assertEq(vm.parseJsonAddress(deploymentJson, ".bagFactoryProxy"), address(deployScript.bagFactoryProxy()));
        assertEq(
            vm.parseJsonAddress(deploymentJson, ".bagFactoryImplementation"),
            address(deployScript.bagFactoryImplementation())
        );
        assertEq(vm.parseJsonAddress(deploymentJson, ".withdrawerImplementation"), address(withdrawerImplementation));
        assertEq(vm.parseJsonAddress(deploymentJson, ".withdrawer"), address(withdrawer));
        assertEq(
            vm.parseJsonAddress(deploymentJson, ".withdrawerProxy"), address(deployScript.requestWithdrawerProxy())
        );
        assertEq(vm.parseJsonAddress(deploymentJson, ".requestPolicy"), address(requestPolicy));
        assertEq(vm.parseJsonAddress(deploymentJson, ".withdrawalRequest"), address(manager));
        assertEq(vm.parseJsonAddress(deploymentJson, ".defaultAdmin"), address(timelock));
        assertEq(vm.parseJsonAddress(deploymentJson, ".resolver"), deployScript.resolver());
        assertEq(vm.parseJsonAddress(deploymentJson, ".configurationManager"), address(timelock));
        assertEq(vm.parseJsonUint(deploymentJson, ".minWithdrawalAmount"), deployScript.minWithdrawalAmount());
        assertEq(vm.parseJsonUint(deploymentJson, ".maxDataLength"), deployScript.MAX_DATA_LENGTH());
        assertEq(vm.parseJsonUint(deploymentJson, ".timelockMinDelay"), deployScript.minDelay());
    }

    function testYnRWAxScriptParams() public {
        DeployYnRWAxWithdrawalRequest deployScript = new DeployYnRWAxWithdrawalRequest();

        assertEq(deployScript.symbol(), "withdrawalRequest-ynRWAx");
        assertEq(deployScript.deploymentToken(), deployScript.YNRWAX());
        assertEq(deployScript.minWithdrawalAmount(), 10_000);
        assertEq(deployScript.MIN_WITHDRAWAL_AMOUNT(), 10_000);
    }

    function testYnRWAxRunDeploysWithOneCentMinimum() public {
        DeployYnRWAxWithdrawalRequestHarness deployScript = new DeployYnRWAxWithdrawalRequestHarness();
        _etchDeploymentToken(deployScript.YNRWAX());

        deployScript.run();
        deployScript._verifySetup();

        WithdrawalRequest manager = deployScript.withdrawalRequest();
        MinAmountRequestPolicy requestPolicy = deployScript.requestPolicy();
        BaseWithdrawer withdrawer = deployScript.requestWithdrawer();

        assertEq(address(withdrawer.token()), deployScript.YNRWAX());
        assertEq(address(manager.requestPolicy()), address(requestPolicy));
        assertEq(requestPolicy.minWithdrawalAmount(), 10_000);

        string memory deploymentJson = vm.readFile(deployScript.deploymentFilePath());
        assertEq(vm.parseJsonAddress(deploymentJson, ".token"), deployScript.YNRWAX());
        assertEq(vm.parseJsonUint(deploymentJson, ".minWithdrawalAmount"), 10_000);
    }

    function testVerifyDeploymentParamsRejectsZeroToken() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(address(0), actor, actor, actor, actor);

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifyDeploymentParamsRejectsZeroProposer() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(MC.YNETHX, address(0), actor, actor, actor);

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifyDeploymentParamsRejectsZeroExecutor() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(MC.YNETHX, actor, address(0), actor, actor);

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifyDeploymentParamsRejectsZeroResolver() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(MC.YNETHX, actor, actor, address(0), actor);

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifyDeploymentParamsRejectsZeroPauser() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(MC.YNETHX, actor, actor, actor, address(0));

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifySetupRejectsUnexpectedProxy() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        deployScript.setPredictedProxy(address(1));

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsZeroTimelock() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        deployScript.setTimelock(TimelockController(payable(address(0))));

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsTimelockWithoutSelfAdmin() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(timelock),
            abi.encodeCall(timelock.hasRole, (timelock.DEFAULT_ADMIN_ROLE(), address(timelock))),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsProposerWithTimelockDefaultAdmin() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(timelock),
            abi.encodeCall(timelock.hasRole, (timelock.DEFAULT_ADMIN_ROLE(), deployScript.proposer())),
            abi.encode(true)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingTimelockProposerRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(timelock),
            abi.encodeCall(timelock.hasRole, (timelock.PROPOSER_ROLE(), deployScript.proposer())),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingTimelockCancellerRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(timelock),
            abi.encodeCall(timelock.hasRole, (timelock.CANCELLER_ROLE(), deployScript.proposer())),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingTimelockExecutorRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(timelock),
            abi.encodeCall(timelock.hasRole, (timelock.EXECUTOR_ROLE(), deployScript.executor())),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingWithdrawalRequestDefaultAdminRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        WithdrawalRequest manager = deployScript.withdrawalRequest();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(manager),
            abi.encodeCall(manager.hasRole, (manager.DEFAULT_ADMIN_ROLE(), address(timelock))),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingWithdrawalRequestConfigurationManagerRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        WithdrawalRequest manager = deployScript.withdrawalRequest();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(manager),
            abi.encodeCall(manager.hasRole, (manager.CONFIGURATION_MANAGER_ROLE(), address(timelock))),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsUnexpectedResolverRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        deployScript.setDeploymentParams(
            deployScript.token(), deployScript.proposer(), deployScript.executor(), address(1), deployScript.pauser()
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsUnexpectedWithdrawer() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        BaseWithdrawer otherWithdrawerImplementation = new BaseWithdrawer();
        BaseWithdrawer otherWithdrawer = BaseWithdrawer(
            address(
                new TransparentUpgradeableProxy(
                    address(otherWithdrawerImplementation),
                    address(deployScript.timelock()),
                    abi.encodeCall(
                        BaseWithdrawer.initialize, (deployScript.token(), address(deployScript.withdrawalRequest()))
                    )
                )
            )
        );
        deployScript.setRequestWithdrawer(otherWithdrawer);

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsUnexpectedRequestPolicy() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        MinAmountRequestPolicy otherRequestPolicy = new MinAmountRequestPolicy(1 ether);
        deployScript.setRequestPolicy(otherRequestPolicy);

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsUnexpectedMaxDataLength() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        WithdrawalRequest manager = deployScript.withdrawalRequest();

        vm.mockCall(address(manager), abi.encodeCall(manager.maxDataLength, ()), abi.encode(uint256(1)));

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingBagFactoryDefaultAdminRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        BeaconProxyFactory bagFactory = deployScript.bagFactory();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(bagFactory),
            abi.encodeCall(bagFactory.hasRole, (bagFactory.DEFAULT_ADMIN_ROLE(), address(timelock))),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingBagFactoryImplementationManagerRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        BeaconProxyFactory bagFactory = deployScript.bagFactory();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(bagFactory),
            abi.encodeCall(bagFactory.hasRole, (bagFactory.IMPLEMENTATION_MANAGER_ROLE(), address(timelock))),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }
}
