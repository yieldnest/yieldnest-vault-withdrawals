// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IBag} from "src/interface/IBag.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {FillRatioResolver} from "test/local/unit/helpers/FillRatioResolver.sol";
import {SetupWithdrawalRequest} from "test/local/unit/helpers/SetupWithdrawalRequest.sol";

contract FillRatioResolverTest is SetupWithdrawalRequest {
    FillRatioResolver fillResolver;

    function setUp() public {
        setUpWithdrawalRequest();
        fillResolver = new FillRatioResolver(manager, address(asset), configurationManager);

        vm.startPrank(admin);
        manager.grantRole(manager.RESOLVER_ROLE(), address(fillResolver));
        manager.revokeRole(manager.RESOLVER_ROLE(), resolver);
        vm.stopPrank();
    }

    function testFillRatioCanOnlyBeSetByManager() public {
        vm.expectRevert(abi.encodeWithSelector(FillRatioResolver.NotFillRatioManager.selector, user));
        vm.prank(user);
        fillResolver.setFillRatioBps(2_500);

        vm.expectEmit(false, false, false, true, address(fillResolver));
        emit FillRatioResolver.FillRatioUpdated(0, 2_500);

        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(2_500);

        assertEq(fillResolver.fillRatioBps(), 2_500);
    }

    function testFillRatioCanOnlyIncreaseUpToOneHundredPercent() public {
        vm.startPrank(configurationManager);
        fillResolver.setFillRatioBps(4_000);

        vm.expectRevert(abi.encodeWithSelector(FillRatioResolver.FillRatioCannotDecrease.selector, 4_000, 3_999));
        fillResolver.setFillRatioBps(3_999);

        vm.expectRevert(abi.encodeWithSelector(FillRatioResolver.FillRatioTooHigh.selector, 10_001));
        fillResolver.setFillRatioBps(10_001);

        fillResolver.setFillRatioBps(10_000);
        vm.stopPrank();

        assertEq(fillResolver.fillRatioBps(), 10_000);
    }

    function testOwnerResolvesOnlyCurrentFillRatioOfInitialLockedAmount() public {
        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(2_500);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(user);
        assertEq(fillResolver.resolveAvailable(id), 2.5 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(fillResolver.initialAmountLocked(id), 10 ether);
        assertEq(request.amountLocked, 7.5 ether);
        assertEq(asset.balanceOf(request.bag), 2.5 ether);
        assertEq(secondAsset.balanceOf(request.bag), 0);
    }

    function testResolveAvailableConvertsShareBudgetToAssetAmount() public {
        ynToken.setAssetRate(2 ether);
        ynToken.setBurnMultiplier(2);

        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(5_000);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(user);
        assertEq(fillResolver.resolveAvailable(id), 5 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(fillResolver.initialAmountLocked(id), 10 ether);
        assertEq(request.amountLocked, 5 ether);
        assertEq(asset.balanceOf(request.bag), 2.5 ether);
    }

    function testRepeatedResolveRequiresFillRatioIncrease() public {
        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(2_500);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(user);
        fillResolver.resolveAvailable(id);

        vm.expectRevert(abi.encodeWithSelector(FillRatioResolver.NothingToResolve.selector, id));
        vm.prank(user);
        fillResolver.resolveAvailable(id);
    }

    function testFillRatioIncreaseResolvesOnlyNewlyAvailableIncrement() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(2_500);
        vm.prank(user);
        assertEq(fillResolver.resolveAvailable(id), 2.5 ether);

        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(6_000);
        vm.prank(user);
        assertEq(fillResolver.resolveAvailable(id), 3.5 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.amountLocked, 4 ether);
        assertEq(asset.balanceOf(request.bag), 6 ether);
    }

    function testOneHundredPercentFillResolvesRemainingAmount() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(4_000);
        vm.prank(user);
        assertEq(fillResolver.resolveAvailable(id), 4 ether);

        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(10_000);
        vm.prank(user);
        assertEq(fillResolver.resolveAvailable(id), 6 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.amountLocked, 0);
        assertEq(asset.balanceOf(request.bag), 10 ether);
    }

    function testOnlyCurrentNftOwnerCanResolveAvailableAmount() public {
        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(5_000);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(abi.encodeWithSelector(FillRatioResolver.NotRequestOwner.selector, receiver, user));
        vm.prank(receiver);
        fillResolver.resolveAvailable(id);

        vm.prank(user);
        manager.transferFrom(user, receiver, id);

        vm.prank(receiver);
        assertEq(fillResolver.resolveAvailable(id), 5 ether);
    }

    function testNewOwnerCanResolveLaterFillRatioIncreaseUsingCachedInitialAmount() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(3_000);
        vm.prank(user);
        assertEq(fillResolver.resolveAvailable(id), 3 ether);

        vm.prank(user);
        manager.transferFrom(user, receiver, id);

        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(7_000);
        vm.prank(receiver);
        assertEq(fillResolver.resolveAvailable(id), 4 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(fillResolver.initialAmountLocked(id), 10 ether);
        assertEq(request.amountLocked, 3 ether);
        assertEq(asset.balanceOf(request.bag), 7 ether);
    }

    function testOldResolverRoleCannotBypassFillRatioResolver() public {
        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(5_000);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert();
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 10 ether);

        vm.prank(user);
        assertEq(fillResolver.resolveAvailable(id), 5 ether);
    }

    function testResolvedAssetsCanBeClaimedFromRequestBag() public {
        vm.prank(configurationManager);
        fillResolver.setFillRatioBps(10_000);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(user);
        fillResolver.resolveAvailable(id);

        WithdrawalRequest.Request memory request = manager.requests(id);

        vm.prank(user);
        assertEq(_claimSingleERC20(request.bag, address(asset), user, 10 ether)[0], 10 ether);
        assertEq(asset.balanceOf(user), 10 ether);
    }

    function _claimSingleERC20(address bag, address asset_, address recipient_, uint256 amount)
        internal
        returns (uint256[] memory)
    {
        address[] memory assets = new address[](1);
        assets[0] = asset_;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        return IBag(bag).claim(assets, payable(recipient_), amounts);
    }
}
