// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {MainnetContracts as MC} from "lib/yieldnest-vault/script/Contracts.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {DeployWithdrawalRequest} from "script/deploy/DeployWithdrawalRequest.s.sol";
import {DeployWithdrawalRequestImplementations} from "script/deploy/DeployWithdrawalRequestImplementations.s.sol";
import {DeployWithdrawalRequestViewer} from "script/deploy/DeployWithdrawalRequestViewer.s.sol";
import {DeployYnRWAxWithdrawalRequest} from "script/deploy/DeployYnRWAxWithdrawalRequest.s.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";
import {WithdrawalRequestDeployer} from "script/WithdrawalRequestDeployer.sol";
import {IWithdrawalRequest} from "src/interface/IWithdrawalRequest.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

error InvalidSetup();

function deployTestImplementations() returns (WithdrawalRequestDeployer.Implementations memory) {
    return WithdrawalRequestDeployer.Implementations({
        withdrawalRequest: address(new WithdrawalRequest()),
        withdrawer: address(new BaseWithdrawer()),
        bagFactory: address(new BeaconProxyFactory()),
        bag: address(new Bag())
    });
}

contract DeploymentTokenMock is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

contract DeployWithdrawalRequestHarness is DeployWithdrawalRequest {
    uint256 private immutable _fileId = vm.randomUint();

    function _loadImplementations() internal override returns (WithdrawalRequestDeployer.Implementations memory) {
        WithdrawalRequestDeployer.Implementations memory implementations = deployTestImplementations();
        vm.serializeAddress("testImplementations", "withdrawalRequestImplementation", implementations.withdrawalRequest);
        vm.serializeAddress("testImplementations", "withdrawerImplementation", implementations.withdrawer);
        vm.serializeAddress("testImplementations", "bagFactoryImplementation", implementations.bagFactory);
        string memory json = vm.serializeAddress("testImplementations", "bagImplementation", implementations.bag);
        vm.writeJson(json, _implementationsFilePath());
        return super._loadImplementations();
    }

    function _implementationsFilePath() internal view override returns (string memory) {
        return string.concat(_deploymentFilePath(), ".implementations.json");
    }

    function _deploymentFilePath() internal view override returns (string memory) {
        return string.concat(
            vm.projectRoot(),
            "/deployments/",
            symbol(),
            "-",
            vm.toString(block.chainid),
            "-",
            vm.toString(address(this)),
            "-",
            vm.toString(_fileId),
            ".json"
        );
    }

    function setDeploymentParams(address token_, address admin_, address resolver_, address pauser_) external {
        token = token_;
        admin = admin_;
        resolver = resolver_;
        pauser = pauser_;
    }

    function setWithdrawalRequest(WithdrawalRequest withdrawalRequest_) external {
        withdrawalRequest = withdrawalRequest_;
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
    function _loadImplementations() internal override returns (WithdrawalRequestDeployer.Implementations memory) {
        return deployTestImplementations();
    }

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

contract DeployWithdrawalRequestViewerHarness is DeployWithdrawalRequestViewer {
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

contract DeployWithdrawalRequestImplementationsHarness is DeployWithdrawalRequestImplementations {
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
    function _deploymentParams() internal returns (WithdrawalRequestDeployer.DeploymentParams memory) {
        return WithdrawalRequestDeployer.DeploymentParams({
            implementations: deployTestImplementations(),
            token: address(new DeploymentTokenMock()),
            admin: address(1),
            resolver: address(3),
            pauser: address(4),
            name: "Test Request",
            symbol: "TEST",
            minWithdrawalAmount: 1 ether,
            maxDataLength: 1024
        });
    }

    function testRunBroadcastsDeployerCreationAndDeploymentAndSupportsRequestLifecycle() public {
        uint256 nonce = vm.getNonce(tx.origin);
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        assertEq(vm.getNonce(tx.origin), nonce + 2);

        WithdrawalRequest manager = deployScript.withdrawalRequest();
        address token = deployScript.token();
        address user = makeAddr("user");
        uint256 amount = 1 ether;
        deal(token, user, amount);
        vm.startPrank(user);
        ERC20(token).approve(address(manager), amount);
        uint256 id = manager.requestWithdrawal(amount, user);
        vm.stopPrank();
        address bag = manager.requests(id).bag;
        assertEq(Bag(payable(bag)).auth(), address(manager));

        vm.prank(deployScript.resolver());
        manager.resolveWithdrawalRequest(id, token, amount);
        assertEq(manager.requests(id).amountLocked, 0);
        assertEq(ERC20(token).balanceOf(bag), amount);
        assertEq(ERC20(token).allowance(address(manager), address(deployScript.requestWithdrawer())), 0);

        address[] memory assets = new address[](1);
        assets[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.startPrank(user);
        Bag(payable(bag)).claim(assets, payable(user), amounts);
        manager.burn(id);
        vm.stopPrank();
        assertEq(ERC20(token).balanceOf(user), amount);
        assertEq(manager.totalSupply(), 0);
    }

    function testDeployerUsesSuppliedImplementationsAndRetainsNoRoles() public {
        WithdrawalRequestDeployer.DeploymentParams memory params = _deploymentParams();
        WithdrawalRequestDeployer deployment = new WithdrawalRequestDeployer();
        assertFalse(deployment.deploymentDone());
        deployment.deploy(params);
        assertTrue(deployment.deploymentDone());
        TimelockController deployedTimelock = deployment.timelock();
        assertTrue(deployedTimelock.hasRole(deployedTimelock.DEFAULT_ADMIN_ROLE(), params.admin));
        assertTrue(deployedTimelock.hasRole(deployedTimelock.PROPOSER_ROLE(), params.admin));
        assertTrue(deployedTimelock.hasRole(deployedTimelock.EXECUTOR_ROLE(), params.admin));
        assertTrue(deployedTimelock.hasRole(deployedTimelock.CANCELLER_ROLE(), params.admin));
        vm.expectRevert(WithdrawalRequestDeployer.DeploymentDone.selector);
        deployment.deploy(params);
        WithdrawalRequest manager = deployment.withdrawalRequest();
        BeaconProxyFactory factory = deployment.bagFactory();
        BaseWithdrawer withdrawer = deployment.withdrawer();
        assertEq(
            address(uint160(uint256(vm.load(address(manager), ERC1967Utils.IMPLEMENTATION_SLOT)))),
            params.implementations.withdrawalRequest
        );
        assertEq(
            address(uint160(uint256(vm.load(address(factory), ERC1967Utils.IMPLEMENTATION_SLOT)))),
            params.implementations.bagFactory
        );
        assertEq(
            address(uint160(uint256(vm.load(address(withdrawer), ERC1967Utils.IMPLEMENTATION_SLOT)))),
            params.implementations.withdrawer
        );
        assertEq(manager.name(), params.name);
        assertEq(manager.symbol(), params.symbol);
        assertTrue(manager.hasRole(manager.PAUSER_ROLE(), params.pauser));
        assertTrue(factory.hasRole(factory.CREATOR_ROLE(), address(manager)));
        address[2] memory temporaryActors = [address(deployment), address(this)];
        for (uint256 i; i < temporaryActors.length; ++i) {
            address actor = temporaryActors[i];
            assertFalse(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), actor));
            assertFalse(manager.hasRole(manager.CONFIGURATION_MANAGER_ROLE(), actor));
            assertFalse(manager.hasRole(manager.RESOLVER_ROLE(), actor));
            assertFalse(manager.hasRole(manager.PAUSER_ROLE(), actor));
            assertFalse(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), actor));
            assertFalse(factory.hasRole(factory.IMPLEMENTATION_MANAGER_ROLE(), actor));
            assertFalse(factory.hasRole(factory.CREATOR_ROLE(), actor));
            TimelockController timelock = deployment.timelock();
            assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), actor));
            assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), actor));
            assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), actor));
        }

        IWithdrawalRequest.InitializeParams memory init;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        manager.initialize(init);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(params.implementations.bag, address(this), address(this), address(this));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        withdrawer.initialize(params.token, address(this));
    }

    function testDeployerRejectsMissingImplementations() public {
        WithdrawalRequestDeployer deployment = new WithdrawalRequestDeployer();
        WithdrawalRequestDeployer.DeploymentParams memory params = _deploymentParams();
        WithdrawalRequestDeployer.Implementations memory implementations = params.implementations;
        address[4] memory originals = [
            implementations.withdrawalRequest,
            implementations.withdrawer,
            implementations.bagFactory,
            implementations.bag
        ];
        for (uint256 i; i < originals.length; ++i) {
            if (i == 0) params.implementations.withdrawalRequest = address(0);
            if (i == 1) params.implementations.withdrawer = address(0);
            if (i == 2) params.implementations.bagFactory = address(0);
            if (i == 3) params.implementations.bag = address(0);
            vm.expectRevert(
                abi.encodeWithSelector(WithdrawalRequestDeployer.InvalidImplementation.selector, address(0))
            );
            deployment.deploy(params);
            assertFalse(deployment.deploymentDone());
            if (i == 0) params.implementations.withdrawalRequest = originals[i];
            if (i == 1) params.implementations.withdrawer = originals[i];
            if (i == 2) params.implementations.bagFactory = originals[i];
            if (i == 3) params.implementations.bag = originals[i];
        }
        deployment.deploy(params);
        assertTrue(deployment.deploymentDone());
    }

    function testDeployerRejectsInvalidConfiguration() public {
        WithdrawalRequestDeployer deployment = new WithdrawalRequestDeployer();
        WithdrawalRequestDeployer.DeploymentParams memory params = _deploymentParams();
        params.token = address(0);
        vm.expectRevert(WithdrawalRequestDeployer.InvalidDeploymentParams.selector);
        deployment.deploy(params);
        params.token = address(new DeploymentTokenMock());
        params.admin = address(0);
        vm.expectRevert(WithdrawalRequestDeployer.InvalidDeploymentParams.selector);
        deployment.deploy(params);
        params.admin = address(1);
        params.minWithdrawalAmount = 0;
        vm.expectRevert(WithdrawalRequestDeployer.InvalidDeploymentParams.selector);
        deployment.deploy(params);
    }

    function _assertProxyAdmins(string memory deploymentJson, address timelock) internal view {
        _assertProxyAdmin(deploymentJson, ".proxy", ".proxyAdmin", timelock);
        _assertProxyAdmin(deploymentJson, ".bagFactoryProxy", ".bagFactoryProxyAdmin", timelock);
        _assertProxyAdmin(deploymentJson, ".withdrawerProxy", ".withdrawerProxyAdmin", timelock);
    }

    function _assertProxyAdmin(
        string memory deploymentJson,
        string memory proxyKey,
        string memory adminKey,
        address timelock
    ) internal view {
        address proxyAddress = vm.parseJsonAddress(deploymentJson, proxyKey);
        address admin = vm.parseJsonAddress(deploymentJson, adminKey);
        assertGt(admin.code.length, 0);
        assertEq(admin, address(uint160(uint256(vm.load(proxyAddress, ERC1967Utils.ADMIN_SLOT)))));
        assertEq(ProxyAdmin(admin).owner(), timelock);
    }

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
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployScript.admin()));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), deployScript.admin()));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), deployScript.admin()));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployScript.admin()));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), deployScript.admin()));
        assertFalse(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(manager.hasRole(manager.CONFIGURATION_MANAGER_ROLE(), address(timelock)));
        assertTrue(manager.hasRole(manager.RESOLVER_ROLE(), deployScript.resolver()));
        assertEq(address(manager.withdrawer()), address(withdrawer));
        assertEq(address(manager.requestPolicy()), address(requestPolicy));
        assertEq(requestPolicy.minWithdrawalAmount(), deployScript.minWithdrawalAmount());
        assertEq(manager.maxDataLength(), deployScript.MAX_DATA_LENGTH());
        assertTrue(bagFactory.hasRole(bagFactory.DEFAULT_ADMIN_ROLE(), deployScript.admin()));
        assertFalse(bagFactory.hasRole(bagFactory.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(bagFactory.hasRole(bagFactory.IMPLEMENTATION_MANAGER_ROLE(), address(timelock)));

        string memory deploymentFilePath = deployScript.deploymentFilePath();
        string memory deploymentJson = vm.readFile(deploymentFilePath);
        assertEq(vm.parseJsonAddress(deploymentJson, ".systemDeployer"), address(deployScript.systemDeployer()));
        _assertProxyAdmins(deploymentJson, address(timelock));
        assertEq(timelock.getMinDelay(), 1 days);

        assertEq(vm.parseJsonAddress(deploymentJson, ".timelock"), address(timelock));
        assertEq(vm.parseJsonAddress(deploymentJson, ".admin"), deployScript.admin());
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
        assertEq(vm.parseJsonAddress(deploymentJson, ".defaultAdmin"), deployScript.admin());
        assertEq(vm.parseJsonAddress(deploymentJson, ".resolver"), deployScript.resolver());
        assertEq(vm.parseJsonAddress(deploymentJson, ".configurationManager"), address(timelock));
        assertEq(vm.parseJsonUint(deploymentJson, ".minWithdrawalAmount"), deployScript.minWithdrawalAmount());
        assertEq(vm.parseJsonUint(deploymentJson, ".maxDataLength"), deployScript.MAX_DATA_LENGTH());
        assertEq(vm.parseJsonUint(deploymentJson, ".timelockMinDelay"), deployScript.minDelay());
    }

    function testViewerOnlyRunDeploysAndRecordsViewer() public {
        DeployWithdrawalRequestViewerHarness deployScript = new DeployWithdrawalRequestViewerHarness();

        assertEq(deployScript.symbol(), "withdrawalRequestViewer");
        assertTrue(bytes(deployScript.deploymentFilePath()).length != 0);

        deployScript.run();
        deployScript._verifySetup();

        WithdrawalRequestViewer viewer = deployScript.withdrawalRequestViewer();
        assertGt(address(viewer).code.length, 0);

        string memory deploymentJson = vm.readFile(deployScript.deploymentFilePath());
        assertEq(vm.parseJsonAddress(deploymentJson, ".viewer"), address(viewer));
        assertEq(vm.parseJsonAddress(deploymentJson, ".deployer"), tx.origin);
    }

    function testImplementationsOnlyRunDeploysAndRecordsImplementations() public {
        DeployWithdrawalRequestImplementationsHarness deployScript = new DeployWithdrawalRequestImplementationsHarness();

        assertEq(deployScript.symbol(), "withdrawalRequestImplementations");
        assertTrue(bytes(deployScript.deploymentFilePath()).length != 0);

        deployScript.run();
        deployScript._verifySetup();

        WithdrawalRequest withdrawalRequestImplementation = deployScript.withdrawalRequestImplementation();
        BaseWithdrawer withdrawerImplementation = deployScript.requestWithdrawerImplementation();
        BeaconProxyFactory bagFactoryImplementation = deployScript.bagFactoryImplementation();
        Bag bagImplementation = deployScript.bagImplementation();

        assertGt(address(withdrawalRequestImplementation).code.length, 0);
        assertGt(address(withdrawerImplementation).code.length, 0);
        assertGt(address(bagFactoryImplementation).code.length, 0);
        assertGt(address(bagImplementation).code.length, 0);

        bytes32 withdrawalRequestId = keccak256("yieldnest.yieldnest-vault-withdrawals.contracts.src.WithdrawalRequest");
        bytes32 withdrawerId =
            keccak256("yieldnest.yieldnest-vault-withdrawals.contracts.src.withdrawers.BaseWithdrawer");
        bytes32 bagFactoryId = keccak256("yieldnest.yieldnest-vault-withdrawals.contracts.src.BeaconProxyFactory");
        bytes32 bagId = keccak256("yieldnest.yieldnest-vault-withdrawals.contracts.src.Bag");

        string memory deploymentJson = vm.readFile(deployScript.deploymentFilePath());
        assertEq(vm.parseJsonBytes32(deploymentJson, ".WITHDRAWAL_REQUEST"), withdrawalRequestId);
        assertEq(vm.parseJsonBytes32(deploymentJson, ".WITHDRAWER"), withdrawerId);
        assertEq(vm.parseJsonBytes32(deploymentJson, ".BAG_FACTORY"), bagFactoryId);
        assertEq(vm.parseJsonBytes32(deploymentJson, ".BAG"), bagId);

        assertEq(
            vm.parseJsonAddress(deploymentJson, string.concat(".", vm.toString(withdrawalRequestId))),
            address(withdrawalRequestImplementation)
        );
        assertEq(
            vm.parseJsonAddress(deploymentJson, string.concat(".", vm.toString(withdrawerId))),
            address(withdrawerImplementation)
        );
        assertEq(
            vm.parseJsonAddress(deploymentJson, string.concat(".", vm.toString(bagFactoryId))),
            address(bagFactoryImplementation)
        );
        assertEq(
            vm.parseJsonAddress(deploymentJson, string.concat(".", vm.toString(bagId))), address(bagImplementation)
        );

        assertEq(
            vm.parseJsonAddress(deploymentJson, ".withdrawalRequestImplementation"),
            address(withdrawalRequestImplementation)
        );
        assertEq(vm.parseJsonAddress(deploymentJson, ".withdrawerImplementation"), address(withdrawerImplementation));
        assertEq(vm.parseJsonAddress(deploymentJson, ".bagFactoryImplementation"), address(bagFactoryImplementation));
        assertEq(vm.parseJsonAddress(deploymentJson, ".bagImplementation"), address(bagImplementation));
        assertEq(vm.parseJsonAddress(deploymentJson, ".deployer"), tx.origin);
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
        _assertProxyAdmins(deploymentJson, address(deployScript.timelock()));
        assertEq(vm.parseJsonUint(deploymentJson, ".minWithdrawalAmount"), 10_000);
    }

    function testVerifyDeploymentParamsRejectsZeroToken() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(address(0), actor, actor, actor);

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifyDeploymentParamsRejectsZeroAdmin() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(MC.YNETHX, address(0), actor, actor);

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifyDeploymentParamsRejectsZeroResolver() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(MC.YNETHX, actor, address(0), actor);

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifyDeploymentParamsRejectsZeroPauser() public {
        DeployWithdrawalRequestHarness deployScript = new DeployWithdrawalRequestHarness();
        address actor = address(1);
        deployScript.setDeploymentParams(MC.YNETHX, actor, actor, address(0));

        vm.expectRevert(InvalidSetup.selector);
        deployScript.verifyDeploymentParams();
    }

    function testVerifySetupRejectsUnexpectedProxy() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        deployScript.setWithdrawalRequest(WithdrawalRequest(address(1)));

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsIncorrectProxyAdminOwner() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        address timelock = address(deployScript.timelock());
        address[3] memory proxies = [
            address(deployScript.proxy()),
            address(deployScript.bagFactoryProxy()),
            address(deployScript.requestWithdrawerProxy())
        ];
        for (uint256 i; i < proxies.length; ++i) {
            address admin = address(uint160(uint256(vm.load(proxies[i], ERC1967Utils.ADMIN_SLOT))));
            vm.prank(timelock);
            ProxyAdmin(admin).transferOwnership(address(1));

            vm.expectRevert(InvalidSetup.selector);
            deployScript._verifySetup();

            vm.prank(address(1));
            ProxyAdmin(admin).transferOwnership(timelock);
        }
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

    function testVerifySetupRejectsMissingTimelockDefaultAdmin() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(timelock),
            abi.encodeCall(timelock.hasRole, (timelock.DEFAULT_ADMIN_ROLE(), deployScript.admin())),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingTimelockProposerRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        TimelockController timelock = deployScript.timelock();

        vm.mockCall(
            address(timelock),
            abi.encodeCall(timelock.hasRole, (timelock.PROPOSER_ROLE(), deployScript.admin())),
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
            abi.encodeCall(timelock.hasRole, (timelock.CANCELLER_ROLE(), deployScript.admin())),
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
            abi.encodeCall(timelock.hasRole, (timelock.EXECUTOR_ROLE(), deployScript.admin())),
            abi.encode(false)
        );

        vm.expectRevert(InvalidSetup.selector);
        deployScript._verifySetup();
    }

    function testVerifySetupRejectsMissingWithdrawalRequestDefaultAdminRole() public {
        DeployWithdrawalRequestHarness deployScript = _deployScript();
        WithdrawalRequest manager = deployScript.withdrawalRequest();

        vm.mockCall(
            address(manager),
            abi.encodeCall(manager.hasRole, (manager.DEFAULT_ADMIN_ROLE(), deployScript.admin())),
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
        deployScript.setDeploymentParams(deployScript.token(), deployScript.admin(), address(1), deployScript.pauser());

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

        vm.mockCall(
            address(bagFactory),
            abi.encodeCall(bagFactory.hasRole, (bagFactory.DEFAULT_ADMIN_ROLE(), deployScript.admin())),
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
