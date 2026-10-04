// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {BaseVault} from "lib/yieldnest-vault/src/BaseVault.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {IWithdrawalRequest} from "src/interface/IWithdrawalRequest.sol";
import {IBag} from "src/interface/IBag.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";

contract UpgradedBagForForkTest is Bag {
    function upgradeMarker() external pure returns (uint256) {
        return 2;
    }
}

contract YnRWAxDeploymentForkTest is Test {
    address internal constant ADMIN = 0xfcad670592a3b24869C0b51a6c6FDED4F95D6975;
    address internal constant YNRWAX = 0x01Ba69727E2860b37bc1a2bd56999c1aFb4C15D8;
    address internal constant MANAGER = 0x6f4f5D74127E6b08b9D3cBa16aabb90D20E01AA7;
    address internal constant FACTORY = 0x974937bf5Ec924673c37Ff0377c48f721F45C091;
    address internal constant WITHDRAWER = 0x20eE049e5A168f162e2FD99429Bd02757678B07F;
    address internal constant TIMELOCK = 0xadb417809C60d7E9b3C72aFEc0DB62F19131e71A;
    address internal constant BEACON = 0xcCc60e35BB91FDBfd047c717dEb907AC547c88a1;
    address internal constant MANAGER_ADMIN = 0x9Bc84665aaBDe314A5a3a613396E41C951DE19B9;
    address internal constant FACTORY_ADMIN = 0x957d1D134861633231234A5753aAc6feB03770dE;
    address internal constant WITHDRAWER_ADMIN = 0x0466910b883A073c1aD223041a0b80b70E5E4494;

    WithdrawalRequest internal manager = WithdrawalRequest(MANAGER);
    BeaconProxyFactory internal factory = BeaconProxyFactory(FACTORY);
    BaseWithdrawer internal withdrawer = BaseWithdrawer(WITHDRAWER);
    BaseVault internal vault = BaseVault(payable(YNRWAX));
    TimelockController internal timelock = TimelockController(payable(TIMELOCK));

    address[5] internal wallets = [
        0x24D2486F5b2C2c225B6be8B4f72D46349cBf4458,
        0x5f33ff3027c4763D36e6f4F7C20eE72F700A5D34,
        0x89Ffc736225bbfaA18aC20a846203CDbe7cC67D6,
        0x69A6Af78fc45F654A1b5feEbC22c1fee88Df8a8F,
        0x4d7B27e0f5D85e41870FE7E680c347bc943231aF
    ];

    function setUp() public {
        vm.createSelectFork("eth_mainnet");
        assertEq(block.chainid, 1);
        assertEq(factory.beacon(), BEACON);
        assertEq(timelock.getMinDelay(), 1 days);
    }

    function testRequestBelowOneYnRWAxReverts() public {
        address wallet = wallets[0];
        uint256 amount = 0.99 ether;
        uint256 walletBalanceBefore = vault.balanceOf(wallet);
        uint256 managerBalanceBefore = vault.balanceOf(MANAGER);
        uint256 requestSupplyBefore = manager.totalSupply();
        uint256 nextIdBefore = manager.nextRequestId();
        assertGe(walletBalanceBefore, amount);
        assertEq(MinAmountRequestPolicy(address(manager.requestPolicy())).minWithdrawalAmount(), 1 ether);

        vm.startPrank(wallet);
        vault.approve(MANAGER, amount);
        vm.expectRevert(abi.encodeWithSelector(MinAmountRequestPolicy.AmountBelowMinimum.selector, amount, 1 ether));
        manager.requestWithdrawal(amount, wallet);
        vm.stopPrank();

        assertEq(vault.balanceOf(wallet), walletBalanceBefore);
        assertEq(vault.balanceOf(MANAGER), managerBalanceBefore);
        assertEq(vault.allowance(wallet, MANAGER), amount);
        assertEq(manager.totalSupply(), requestSupplyBefore);
        assertEq(manager.nextRequestId(), nextIdBefore);
        assertFalse(manager.requestExists(nextIdBefore));
    }

    function testUpgradeThroughTimelockThenLockFullBalancePerWallet() public {
        _upgradeThroughTimelock();
        _grantVaultWithdrawerRole();

        uint256 managerBalanceBefore = vault.balanceOf(MANAGER);
        uint256 vaultSupplyBefore = vault.totalSupply();
        uint256 requestSupplyBefore = manager.totalSupply();
        uint256 firstId = manager.nextRequestId();
        uint256 totalLocked;
        emit log_named_decimal_uint("Module ynRWAx balance before requests", managerBalanceBefore, 18);
        for (uint256 i; i < wallets.length; ++i) {
            address wallet = wallets[i];
            assertGt(wallet.code.length, 0);
            uint256 balanceBefore = vault.balanceOf(wallet);
            emit log_named_address("Wallet", wallet);
            emit log_named_decimal_uint("Wallet ynRWAx before request", balanceBefore, 18);
            uint256 ownedBefore = manager.balanceOf(wallet);
            assertGe(balanceBefore, 1 ether, "wallet must hold the minimum request amount");

            uint256 id = _request(wallet, balanceBefore);
            emit log_named_uint("Request ID", id);
            emit log_named_decimal_uint("Wallet ynRWAx after request", vault.balanceOf(wallet), 18);
            assertEq(id, firstId + i);
            assertEq(UpgradedBagForForkTest(payable(manager.requests(id).bag)).upgradeMarker(), 2);
            assertEq(vault.balanceOf(wallet), 0);
            assertEq(manager.balanceOf(wallet), ownedBefore + 1);
            totalLocked += balanceBefore;
            assertEq(vault.balanceOf(MANAGER), managerBalanceBefore + totalLocked);
        }

        uint256 recordedLocked;
        for (uint256 id = firstId; id < firstId + wallets.length; ++id) {
            recordedLocked += manager.requests(id).amountLocked;
        }
        assertEq(recordedLocked, totalLocked);
        emit log_named_decimal_uint("ynRWAx locked by these requests", recordedLocked, 18);
        emit log_named_address("Withdrawal request module", MANAGER);
        emit log_named_decimal_uint("Final module ynRWAx balance", vault.balanceOf(MANAGER), 18);
        assertEq(
            vault.balanceOf(MANAGER),
            managerBalanceBefore + recordedLocked,
            "withdrawal request module must hold all locked ynRWAx shares"
        );
        assertEq(manager.totalSupply(), requestSupplyBefore + wallets.length);
        assertEq(manager.nextRequestId(), firstId + wallets.length);
        assertEq(vault.totalSupply(), vaultSupplyBefore, "locking must not burn or mint shares");
        assertEq(vault.allowance(MANAGER, WITHDRAWER), 0);
    }

    function testUpgradePreservesExistingRequestAndUpdatesExistingBag() public {
        uint256 id = _request(wallets[0], vault.balanceOf(wallets[0]));
        IWithdrawalRequest.Request memory beforeRequest = manager.requests(id);
        uint256 lockedBefore = vault.balanceOf(MANAGER);
        uint256 nextIdBefore = manager.nextRequestId();
        uint256 supplyBefore = manager.totalSupply();

        _upgradeThroughTimelock();

        assertEq(keccak256(abi.encode(manager.requests(id))), keccak256(abi.encode(beforeRequest)));
        assertEq(manager.ownerOf(id), wallets[0]);
        assertEq(manager.nextRequestId(), nextIdBefore);
        assertEq(manager.totalSupply(), supplyBefore);
        assertEq(vault.balanceOf(MANAGER), lockedBefore);
        assertEq(IBag(beforeRequest.bag).auth(), MANAGER);
        assertEq(IBag(beforeRequest.bag).id(), id);
        assertEq(UpgradedBagForForkTest(payable(beforeRequest.bag)).upgradeMarker(), 2);
        assertEq(address(uint160(uint256(vm.load(beforeRequest.bag, ERC1967Utils.BEACON_SLOT)))), BEACON);
    }

    function _request(address wallet, uint256 amount) internal returns (uint256 id) {
        uint256 walletBalanceBefore = vault.balanceOf(wallet);
        uint256 managerBalanceBefore = vault.balanceOf(MANAGER);
        uint256 rateBefore = vault.convertToAssets(1 ether);
        bytes memory data = abi.encode(wallet, amount);
        vm.startPrank(wallet);
        vault.approve(MANAGER, amount);
        id = manager.requestWithdrawal(amount, wallet, data);
        vm.stopPrank();

        IWithdrawalRequest.Request memory request = manager.requests(id);
        assertTrue(manager.requestExists(id));
        assertEq(manager.ownerOf(id), wallet);
        assertEq(request.amountLocked, amount);
        assertEq(request.rateAtRequest, rateBefore);
        assertEq(request.data, data);
        assertEq(request.assetsRedeemed.length, 0);
        assertGt(request.bag.code.length, 0);
        assertEq(IBag(request.bag).auth(), MANAGER);
        assertEq(IBag(request.bag).id(), id);
        assertEq(vault.balanceOf(wallet), walletBalanceBefore - amount);
        assertEq(vault.balanceOf(MANAGER), managerBalanceBefore + amount);
        assertEq(vault.balanceOf(request.bag), 0, "locked shares stay in the manager, not the bag");
        assertEq(vault.allowance(wallet, MANAGER), 0);
    }

    function _grantVaultWithdrawerRole() internal {
        bytes32 role = vault.ASSET_WITHDRAWER_ROLE();
        assertTrue(vault.hasRole(vault.getRoleAdmin(role), ADMIN));
        vm.prank(ADMIN);
        vault.grantRole(role, WITHDRAWER);
        assertTrue(vault.hasRole(role, WITHDRAWER));
    }

    function _upgradeThroughTimelock() internal {
        address[] memory proxies = new address[](3);
        proxies[0] = MANAGER;
        proxies[1] = FACTORY;
        proxies[2] = WITHDRAWER;
        address[] memory implementations = new address[](3);
        implementations[0] = address(new WithdrawalRequest());
        implementations[1] = address(new BeaconProxyFactory());
        implementations[2] = address(new BaseWithdrawer());
        address newBag = address(new UpgradedBagForForkTest());
        address policyBefore = address(manager.requestPolicy());
        uint256 maxDataBefore = manager.maxDataLength();

        address[] memory targets = new address[](4);
        targets[0] = MANAGER_ADMIN;
        targets[1] = FACTORY_ADMIN;
        targets[2] = WITHDRAWER_ADMIN;
        targets[3] = FACTORY;
        uint256[] memory values = new uint256[](4);
        bytes[] memory payloads = new bytes[](4);
        for (uint256 i; i < proxies.length; ++i) {
            assertEq(ProxyAdmin(targets[i]).owner(), TIMELOCK);
            assertEq(address(uint160(uint256(vm.load(proxies[i], ERC1967Utils.ADMIN_SLOT)))), targets[i]);
            assertTrue(
                address(uint160(uint256(vm.load(proxies[i], ERC1967Utils.IMPLEMENTATION_SLOT)))) != implementations[i]
            );
            payloads[i] = abi.encodeCall(
                ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxies[i]), implementations[i], bytes(""))
            );
        }
        payloads[3] = abi.encodeCall(BeaconProxyFactory.upgradeImplementation, (newBag));
        bytes32 salt = keccak256("ynRWAx fork upgrade");
        bytes32 operation = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);

        uint256 delay = timelock.getMinDelay();
        vm.prank(ADMIN);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        assertTrue(timelock.isOperationPending(operation));
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                operation,
                bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready))
            )
        );
        vm.prank(ADMIN);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        vm.warp(block.timestamp + 1 days);
        vm.prank(ADMIN);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        assertTrue(timelock.isOperationDone(operation));
        for (uint256 i; i < proxies.length; ++i) {
            assertEq(
                address(uint160(uint256(vm.load(proxies[i], ERC1967Utils.IMPLEMENTATION_SLOT)))), implementations[i]
            );
            assertEq(ProxyAdmin(targets[i]).owner(), TIMELOCK);
        }
        assertEq(factory.beacon(), BEACON);
        assertEq(factory.implementation(), newBag);
        assertEq(address(manager.token()), YNRWAX);
        assertEq(address(manager.bagFactory()), FACTORY);
        assertEq(address(manager.withdrawer()), WITHDRAWER);
        assertEq(address(manager.requestPolicy()), policyBefore);
        assertEq(manager.maxDataLength(), maxDataBefore);
        assertEq(manager.name(), "ynRWAx Withdrawal Request");
        assertEq(manager.symbol(), "ynWREQ-ynRWAx");
        assertEq(address(withdrawer.token()), YNRWAX);
        assertEq(withdrawer.withdrawalRequest(), MANAGER);
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(manager.hasRole(manager.RESOLVER_ROLE(), ADMIN));
        assertTrue(manager.hasRole(manager.CONFIGURATION_MANAGER_ROLE(), TIMELOCK));
        assertTrue(factory.hasRole(factory.CREATOR_ROLE(), MANAGER));
        assertTrue(factory.hasRole(factory.IMPLEMENTATION_MANAGER_ROLE(), TIMELOCK));
    }
}
