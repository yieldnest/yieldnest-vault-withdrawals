// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {BaseVault} from "lib/yieldnest-vault/src/BaseVault.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {MainnetActors as Actors} from "lib/yieldnest-vault/script/Actors.sol";
import {MainnetContracts as MC} from "lib/yieldnest-vault/script/Contracts.sol";
import {IBag} from "src/interface/IBag.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract WithdrawalRequestMainnetTest is Test, Actors {
    BaseVault public vault;
    WithdrawalRequest public manager;
    WithdrawalRequestViewer public viewer;
    Bag public bagImplementation;
    BeaconProxyFactory public proxyFactoryImplementation;
    BeaconProxyFactory public proxyFactory;

    address public requester;
    address public fulfiller;
    address public configurationManager;
    address public pauser;

    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 1e15;

    function setUp() public {
        vault = BaseVault(payable(MC.YNETHX));
        viewer = new WithdrawalRequestViewer();

        requester = makeAddr("requester");
        fulfiller = makeAddr("fulfiller");
        configurationManager = makeAddr("configurationManager");
        pauser = makeAddr("pauser");

        bagImplementation = new Bag();
        proxyFactoryImplementation = new BeaconProxyFactory();
        ERC1967Proxy proxyFactoryProxy = new ERC1967Proxy(
            address(proxyFactoryImplementation),
            abi.encodeCall(BeaconProxyFactory.initialize, (address(bagImplementation), ADMIN, ADMIN, ADMIN))
        );
        proxyFactory = BeaconProxyFactory(address(proxyFactoryProxy));

        WithdrawalRequest implementation = new WithdrawalRequest();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                WithdrawalRequest.initialize,
                (
                    address(vault),
                    ADMIN,
                    fulfiller,
                    configurationManager,
                    pauser,
                    address(proxyFactory),
                    MIN_WITHDRAWAL_AMOUNT
                )
            )
        );
        manager = WithdrawalRequest(address(proxy));

        bytes32 creatorRole = proxyFactory.CREATOR_ROLE();
        vm.prank(ADMIN);
        proxyFactory.grantRole(creatorRole, address(manager));

        vm.startPrank(ADMIN);
        vault.grantRole(vault.ASSET_WITHDRAWER_ROLE(), address(manager));
        vault.grantRole(vault.ASSET_MANAGER_ROLE(), address(this));
        vm.stopPrank();

        _activateAsset(MC.WETH);
        _activateAsset(MC.WSTETH);
        _activateAsset(MC.WOETH);

        vault.processAccounting();
    }

    function _claimSingleERC20(address bag, address asset, address recipient, uint256 amount) internal returns (uint256) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        return IBag(bag).claim(assets, payable(recipient), amounts)[0];
    }

    function test_withdrawalRequest_fulfillsWETHWithdrawal() public {
        uint256 depositedShares = _depositIntoYnETHx(MC.WETH, requester, 10 ether);
        uint256 requestId = _requestWithdrawal(requester, depositedShares);

        uint256 managerShareBalanceBefore = IERC20(address(vault)).balanceOf(address(manager));
        uint256 totalSupplyBefore = vault.totalSupply();

        vm.prank(fulfiller);
        uint256 burnedShares = manager.fulfillWithdrawalRequest(requestId, MC.WETH, 2 ether);

        WithdrawalRequest.Request memory request = manager.requests(requestId);
        assertEq(IERC20(MC.WETH).balanceOf(request.bag), 2 ether);
        assertEq(IERC20(MC.WETH).balanceOf(requester), 0);
        assertEq(IERC20(MC.WETH).balanceOf(address(manager)), 0);
        assertEq(IERC20(address(vault)).balanceOf(address(manager)), managerShareBalanceBefore - burnedShares);
        assertEq(request.amountLocked, depositedShares - burnedShares);
        assertEq(vault.totalSupply(), totalSupplyBefore - burnedShares);

        vm.prank(requester);
        assertEq(_claimSingleERC20(request.bag, MC.WETH, requester, 2 ether), 2 ether);
        assertEq(IERC20(MC.WETH).balanceOf(requester), 2 ether);
    }

    function test_withdrawalRequest_fulfillsMaxWETHWithdrawal() public {
        uint256 depositedShares = _depositIntoYnETHx(MC.WETH, requester, 10 ether);
        uint256 requestId = _requestWithdrawal(requester, depositedShares);

        uint256 maxAssets = viewer.convertToAssets(manager, MC.WETH, depositedShares);
        assertGt(maxAssets, 0);

        vm.prank(fulfiller);
        uint256 burnedShares = manager.fulfillWithdrawalRequest(requestId, MC.WETH, maxAssets);

        WithdrawalRequest.Request memory request = manager.requests(requestId);
        assertEq(IERC20(MC.WETH).balanceOf(request.bag), maxAssets);
        assertEq(IERC20(MC.WETH).balanceOf(requester), 0);
        assertEq(IERC20(MC.WETH).balanceOf(address(manager)), 0);
        assertGt(burnedShares, 0);
        assertLt(request.amountLocked, depositedShares);

        vm.prank(requester);
        assertEq(_claimSingleERC20(request.bag, MC.WETH, requester, maxAssets), maxAssets);
        assertEq(IERC20(MC.WETH).balanceOf(requester), maxAssets);
    }

    function test_withdrawalRequest_fulfillMaxDoesNotBurnMoreThanLockedShares(uint256 assetIndex, uint256 depositAmount)
        public
    {
        address[3] memory assets = [MC.WETH, MC.WSTETH, MC.WOETH];
        address asset = assets[bound(assetIndex, 0, assets.length - 1)];
        depositAmount = bound(depositAmount, 5 ether, 100 ether);

        uint256 depositedShares = _depositIntoYnETHx(asset, requester, depositAmount);
        uint256 requestId = _requestWithdrawal(requester, depositedShares);
        uint256 maxAssets = viewer.maxFulfillmentAssets(manager, requestId, asset);

        vm.prank(fulfiller);
        uint256 burnedShares = manager.fulfillWithdrawalRequest(requestId, asset, maxAssets);

        WithdrawalRequest.Request memory request = manager.requests(requestId);
        assertLe(burnedShares, depositedShares);
        assertEq(request.amountLocked, depositedShares - burnedShares);
    }

    function test_withdrawalRequest_convertToAssetsForLiveYnETHx(uint256 assetIndex, uint256 shares) public view {
        address[3] memory assets = [MC.WETH, MC.WSTETH, MC.WOETH];
        address asset = assets[bound(assetIndex, 0, assets.length - 1)];
        shares = bound(shares, 1e15, 100 ether);

        uint256 assetsForShares = viewer.convertToAssets(manager, asset, shares);

        assertGt(assetsForShares, 0);
        assertLe(assetsForShares, type(uint128).max);
    }

    function test_withdrawalRequest_fulfillsMultiAssetWithdrawal(
        uint256 assetIndex,
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        address[3] memory assets = [MC.WETH, MC.WSTETH, MC.WOETH];
        address asset = assets[bound(assetIndex, 0, assets.length - 1)];

        depositAmount = bound(depositAmount, 5 ether, 100 ether);
        withdrawAmount = bound(withdrawAmount, 1e15, depositAmount / 2);

        uint256 depositedShares = _depositIntoYnETHx(asset, requester, depositAmount);
        uint256 requestId = _requestWithdrawal(requester, depositedShares);

        uint256 managerAssetBalanceBefore = IERC20(asset).balanceOf(address(manager));

        vm.prank(fulfiller);
        uint256 burnedShares = manager.fulfillWithdrawalRequest(requestId, asset, withdrawAmount);

        WithdrawalRequest.Request memory request = manager.requests(requestId);
        assertEq(IERC20(asset).balanceOf(request.bag), withdrawAmount);
        assertEq(IERC20(asset).balanceOf(requester), 0);
        assertEq(IERC20(asset).balanceOf(address(manager)), managerAssetBalanceBefore);
        assertEq(manager.ownerOf(requestId), requester);
        assertEq(request.amountLocked, depositedShares - burnedShares);
        assertGt(burnedShares, 0);

        vm.prank(requester);
        assertEq(_claimSingleERC20(request.bag, asset, requester, withdrawAmount), withdrawAmount);
        assertEq(IERC20(asset).balanceOf(requester), withdrawAmount);
    }

    function test_withdrawalRequest_fulfillsPartialWithdrawals(uint256 firstWithdraw, uint256 secondWithdraw) public {
        uint256 depositAmount = 20 ether;
        firstWithdraw = bound(firstWithdraw, 1e15, 5 ether);
        secondWithdraw = bound(secondWithdraw, 1e15, 5 ether);

        uint256 depositedShares = _depositIntoYnETHx(MC.WETH, requester, depositAmount);
        uint256 requestId = _requestWithdrawal(requester, depositedShares);

        vm.prank(fulfiller);
        uint256 firstBurned = manager.fulfillWithdrawalRequest(requestId, MC.WETH, firstWithdraw);

        WithdrawalRequest.Request memory requestAfterFirst = manager.requests(requestId);
        assertEq(requestAfterFirst.amountLocked, depositedShares - firstBurned);

        vm.prank(fulfiller);
        uint256 secondBurned = manager.fulfillWithdrawalRequest(requestId, MC.WETH, secondWithdraw);

        WithdrawalRequest.Request memory requestAfterSecond = manager.requests(requestId);
        assertEq(requestAfterSecond.amountLocked, depositedShares - firstBurned - secondBurned);
        assertEq(IERC20(MC.WETH).balanceOf(requestAfterSecond.bag), firstWithdraw + secondWithdraw);
        assertEq(IERC20(MC.WETH).balanceOf(requester), 0);
        assertEq(IERC20(MC.WETH).balanceOf(address(manager)), 0);

        vm.prank(requester);
        assertEq(
            _claimSingleERC20(requestAfterSecond.bag, MC.WETH, requester, firstWithdraw + secondWithdraw),
            firstWithdraw + secondWithdraw
        );
        assertEq(IERC20(MC.WETH).balanceOf(requester), firstWithdraw + secondWithdraw);
    }

    function test_withdrawalRequest_revertsWhenFulfillmentWouldBurnMoreThanLocked() public {
        uint256 depositedShares = _depositIntoYnETHx(MC.WETH, requester, 2 ether);
        uint256 requestId = _requestWithdrawal(requester, depositedShares / 4);

        vm.expectRevert();
        vm.prank(fulfiller);
        manager.fulfillWithdrawalRequest(requestId, MC.WETH, 1 ether);
    }

    function test_withdrawalRequest_revertsForUnauthorizedFulfiller() public {
        uint256 depositedShares = _depositIntoYnETHx(MC.WETH, requester, 5 ether);
        uint256 requestId = _requestWithdrawal(requester, depositedShares);

        vm.expectRevert();
        vm.prank(makeAddr("notFulfiller"));
        manager.fulfillWithdrawalRequest(requestId, MC.WETH, 1 ether);
    }

    function test_withdrawalRequest_respectsMinimumAndPause() public {
        vm.prank(configurationManager);
        manager.setMinWithdrawalAmount(2 ether);

        uint256 depositedShares = _depositIntoYnETHx(MC.WETH, requester, 5 ether);

        vm.startPrank(requester);
        IERC20(address(vault)).approve(address(manager), depositedShares);
        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.AmountBelowMinimum.selector, 1 ether, 2 ether));
        manager.requestWithdrawal(1 ether, requester);
        vm.stopPrank();

        vm.prank(pauser);
        manager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(requester);
        manager.requestWithdrawal(depositedShares, requester);
    }

    function test_withdrawalRequest_revertsForInvalidRequestAndZeroAmounts() public {
        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.RequestNotFound.selector, 123));
        vm.prank(fulfiller);
        manager.fulfillWithdrawalRequest(123, MC.WETH, 1 ether);

        uint256 depositedShares = _depositIntoYnETHx(MC.WETH, requester, 5 ether);
        uint256 requestId = _requestWithdrawal(requester, depositedShares);

        vm.expectRevert(WithdrawalRequest.ZeroAmount.selector);
        vm.prank(fulfiller);
        manager.fulfillWithdrawalRequest(requestId, MC.WETH, 0);

        vm.expectRevert(WithdrawalRequest.ZeroAddress.selector);
        vm.prank(fulfiller);
        manager.fulfillWithdrawalRequest(requestId, address(0), 1 ether);
    }

    function _depositIntoYnETHx(address asset, address receiver, uint256 amount) internal returns (uint256 shares) {
        deal(asset, receiver, amount);

        vm.startPrank(receiver);
        IERC20(asset).approve(address(vault), amount);
        shares = vault.depositAsset(asset, amount, receiver);
        vm.stopPrank();

        assertGt(shares, 0);
    }

    function _requestWithdrawal(address owner, uint256 amount) internal returns (uint256 requestId) {
        vm.startPrank(owner);
        IERC20(address(vault)).approve(address(manager), amount);
        requestId = manager.requestWithdrawal(amount, owner);
        vm.stopPrank();

        WithdrawalRequest.Request memory request = manager.requests(requestId);
        assertTrue(manager.requestExists(requestId));
        assertFalse(manager.requestExists(requestId + 1));
        assertEq(address(manager.proxyFactory()), address(proxyFactory));
        assertTrue(request.bag != address(0));
        assertEq(manager.ownerOf(requestId), owner);
        assertEq(IBag(request.bag).ownerRegistry(), address(manager));
        assertEq(request.amountLocked, amount);
        assertEq(IERC20(address(vault)).balanceOf(address(manager)), amount);
    }

    function _activateAsset(address asset) internal {
        IVault.AssetParams memory params = vault.getAsset(asset);
        vault.updateAsset(params.index, IVault.AssetUpdateFields({active: true}));
    }
}
