// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAccessControl} from "lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Enumerable} from "lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {IBag} from "src/interface/IBag.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";
import {Bag} from "src/Bag.sol";
import {MinAmountRequestPolicy} from "src/request-policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {FixedRateWithdrawer} from "src/withdrawers/FixedRateWithdrawer.sol";
import {SetupWithdrawalRequest} from "test/local/unit/helpers/SetupWithdrawalRequest.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract ReentrantResolveWithdrawer is IWithdrawer {
    WithdrawalRequest internal manager;
    address internal reentrantAsset;

    function arm(WithdrawalRequest manager_, address reentrantAsset_) external {
        manager = manager_;
        reentrantAsset = reentrantAsset_;
    }

    function withdrawAsset(uint256 requestId, address, uint256, address, address) external returns (uint256) {
        manager.resolveWithdrawalRequest(requestId, reentrantAsset, 1);
        return 0;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract WithdrawalRequestTest is SetupWithdrawalRequest {
    function setUp() public {
        setUpWithdrawalRequest();
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

    function _claimSingleNative(address bag, address payable recipient_, uint256 amount)
        internal
        returns (uint256[] memory)
    {
        address[] memory assets = new address[](1);
        assets[0] = ETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        return IBag(bag).claim(assets, recipient_, amounts);
    }

    function _defaultInitializeCall(
        address token_,
        address admin_,
        address resolver_,
        address configurationManager_,
        address pauser_,
        address bagFactory_,
        address withdrawer_,
        address requestPolicy_
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            WithdrawalRequest.initialize,
            (token_, admin_, resolver_, configurationManager_, pauser_, bagFactory_, withdrawer_, requestPolicy_)
        );
    }

    function _expectInitializeRevertsForZeroAddress(
        address token_,
        address admin_,
        address resolver_,
        address configurationManager_,
        address pauser_,
        address bagFactory_,
        address withdrawer_,
        address requestPolicy_
    ) internal {
        WithdrawalRequest implementation = new WithdrawalRequest();

        vm.expectRevert(WithdrawalRequest.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            _defaultInitializeCall(
                token_, admin_, resolver_, configurationManager_, pauser_, bagFactory_, withdrawer_, requestPolicy_
            )
        );
    }

    function testImplementationCannotBeInitialized() public {
        WithdrawalRequest implementation = new WithdrawalRequest();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy)
        );
    }

    function testProxyCannotBeInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        manager.initialize(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy)
        );
    }

    function testInitializeRevertsForZeroDependencies() public {
        _expectInitializeRevertsForZeroAddress(
            address(0),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy)
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            address(0),
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy)
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            address(0),
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy)
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            address(0),
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy)
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            address(0),
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy)
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(0),
            address(withdrawer),
            address(requestPolicy)
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(0),
            address(requestPolicy)
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(0)
        );
    }

    function testRequestWithdrawalTransfersTokenAndRecordsRequest() public {
        vm.expectEmit(true, false, true, false, address(manager));
        emit WithdrawalRequest.WithdrawalRequested(0, user, address(ynToken), address(0), 10 ether);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        assertEq(id, 0);
        assertEq(manager.nextRequestId(), 1);
        assertEq(address(manager.bagFactory()), address(bagFactory));
        assertTrue(manager.requestExists(id));
        assertFalse(manager.requestExists(id + 1));
        assertEq(ynToken.balanceOf(user), 90 ether);
        assertEq(ynToken.balanceOf(address(manager)), 10 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertTrue(request.bag != address(0));
        assertEq(manager.ownerOf(id), user);
        assertEq(manager.name(), "MAX Vault Withdrawal Request");
        assertEq(manager.symbol(), "ynWREQ");
        assertEq(address(manager.withdrawer()), address(withdrawer));
        assertEq(address(manager.requestPolicy()), address(requestPolicy));
        assertEq(ynToken.allowance(address(manager), address(withdrawer)), type(uint256).max);
        assertTrue(manager.supportsInterface(type(IERC721Enumerable).interfaceId));
        assertEq(IBag(request.bag).ownerRegistry(), address(manager));
        assertEq(IBag(request.bag).id(), id);
        assertEq(request.amountLocked, 10 ether);
        assertEq(request.rateAtRequest, 1 ether);
    }

    function testRequestWithdrawalRecordsRateAtCreation() public {
        ynToken.setConvertToAssetsRate(2 ether);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        ynToken.setConvertToAssetsRate(3 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.amountLocked, 10 ether);
        assertEq(request.rateAtRequest, 2 ether);
    }

    function testRequestWithdrawalCreatesBagForEachRequest() public {
        vm.startPrank(user);
        uint256 firstId = manager.requestWithdrawal(10 ether, user);
        uint256 secondId = manager.requestWithdrawal(11 ether, user);
        vm.stopPrank();

        WithdrawalRequest.Request memory firstRequest = manager.requests(firstId);
        WithdrawalRequest.Request memory secondRequest = manager.requests(secondId);

        assertTrue(firstRequest.bag != address(0));
        assertTrue(secondRequest.bag != address(0));
        assertTrue(firstRequest.bag != secondRequest.bag);
        assertEq(manager.ownerOf(firstId), user);
        assertEq(manager.ownerOf(secondId), user);
        assertEq(manager.totalSupply(), 2);
        assertEq(manager.tokenByIndex(0), firstId);
        assertEq(manager.tokenByIndex(1), secondId);
        assertEq(manager.tokenOfOwnerByIndex(user, 0), firstId);
        assertEq(manager.tokenOfOwnerByIndex(user, 1), secondId);
        assertEq(IBag(firstRequest.bag).ownerRegistry(), address(manager));
        assertEq(IBag(secondRequest.bag).ownerRegistry(), address(manager));
    }

    function testRequestWithdrawalMintsRequestNFTToReceiver() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        WithdrawalRequest.Request memory request = manager.requests(id);

        assertEq(ynToken.balanceOf(user), 90 ether);
        assertEq(ynToken.balanceOf(address(manager)), 10 ether);
        assertEq(manager.ownerOf(id), receiver);
        assertEq(manager.balanceOf(receiver), 1);
        assertEq(manager.tokenOfOwnerByIndex(receiver, 0), id);
        assertEq(IBag(request.bag).ownerRegistry(), address(manager));
        assertEq(IBag(request.bag).id(), id);
    }

    function testRequestNFTEnumerableTracksTransfers() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        vm.prank(receiver);
        manager.transferFrom(receiver, user, id);

        assertEq(manager.balanceOf(receiver), 0);
        assertEq(manager.balanceOf(user), 1);
        assertEq(manager.tokenOfOwnerByIndex(user, 0), id);
    }

    function testViewerReturnsFullRequestPicture() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        WithdrawalRequest.Request memory request = manager.requests(id);
        WithdrawalRequestViewer.RequestView memory view_ = viewer.getRequest(manager, id);

        assertEq(view_.owner, receiver);
        assertEq(view_.bag, request.bag);
        assertEq(view_.token, address(ynToken));
        assertEq(view_.amountLocked, 10 ether);
        assertEq(view_.rateAtRequest, 1 ether);
        assertEq(view_.tokenBalance, 10 ether);
        assertEq(view_.assetBalances.length, 0);
    }

    function testViewerReturnsBagAssetBalancesAfterResolution() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 4 ether);

        WithdrawalRequestViewer.RequestView memory view_ = viewer.getRequest(manager, id);

        assertEq(view_.owner, receiver);
        assertEq(view_.amountLocked, 6 ether);
        assertEq(view_.tokenBalance, 6 ether);
        assertEq(view_.assetBalances.length, 1);
        assertEq(view_.assetBalances[0].asset, address(asset));
        assertEq(view_.assetBalances[0].balance, 4 ether);
    }

    function testFuzzRequestWithdrawalTransfersTokenAndMintsRequestNFTToReceiver(uint96 amount, address receiver_)
        public
    {
        amount = uint96(bound(amount, minWithdrawalAmount, ynToken.balanceOf(user)));
        vm.assume(receiver_ != address(0));

        uint256 userBalanceBefore = ynToken.balanceOf(user);
        uint256 managerBalanceBefore = ynToken.balanceOf(address(manager));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(amount, receiver_);

        WithdrawalRequest.Request memory request = manager.requests(id);

        assertEq(id, 0);
        assertTrue(manager.requestExists(id));
        assertFalse(manager.requestExists(id + 1));
        assertEq(ynToken.balanceOf(user), userBalanceBefore - amount);
        assertEq(ynToken.balanceOf(address(manager)), managerBalanceBefore + amount);
        assertEq(request.amountLocked, amount);
        assertEq(manager.ownerOf(id), receiver_);
        assertEq(IBag(request.bag).ownerRegistry(), address(manager));
        assertEq(IBag(request.bag).id(), id);
    }

    function testBagFactoryRequiresCreatorRole() public {
        bytes32 creatorRole = bagFactory.CREATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, creatorRole)
        );
        vm.prank(user);
        bagFactory.create(abi.encodeCall(IBag.initialize, (address(manager), 1)));
    }

    function testBagFactoryUpgradesImplementation() public {
        Bag newImplementation = new Bag();

        vm.prank(admin);
        bagFactory.upgradeImplementation(address(newImplementation));

        assertEq(bagFactory.implementation(), address(newImplementation));
    }

    function testBagClaimRequiresRequestOwner() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        asset.mint(request.bag, 4 ether);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, address(this)));
        _claimSingleERC20(request.bag, address(asset), user, 4 ether);

        vm.prank(user);
        uint256 amountClaimed = _claimSingleERC20(request.bag, address(asset), user, 4 ether)[0];

        assertEq(amountClaimed, 4 ether);
        assertEq(asset.balanceOf(user), 4 ether);
        assertEq(asset.balanceOf(request.bag), 0);
    }

    function testBagClaimRejectsApprovedRequestOperator() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        asset.mint(request.bag, 4 ether);

        vm.prank(user);
        manager.approve(receiver, id);

        assertTrue(manager.isAuthorized(receiver, id));

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, receiver));
        vm.prank(receiver);
        _claimSingleERC20(request.bag, address(asset), receiver, 4 ether);

        vm.prank(user);
        uint256 amountClaimed = _claimSingleERC20(request.bag, address(asset), user, 4 ether)[0];

        assertEq(amountClaimed, 4 ether);
        assertEq(asset.balanceOf(user), 4 ether);
        assertEq(asset.balanceOf(request.bag), 0);
    }

    function testBagClaimRejectsApprovedForAllRequestOperator() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        asset.mint(request.bag, 4 ether);

        vm.prank(user);
        manager.setApprovalForAll(receiver, true);

        assertTrue(manager.isAuthorized(receiver, id));

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, receiver));
        vm.prank(receiver);
        _claimSingleERC20(request.bag, address(asset), receiver, 4 ether);

        vm.prank(user);
        uint256 amountClaimed = _claimSingleERC20(request.bag, address(asset), user, 4 ether)[0];

        assertEq(amountClaimed, 4 ether);
        assertEq(asset.balanceOf(user), 4 ether);
        assertEq(asset.balanceOf(request.bag), 0);
    }

    function testBagClaimSingleNativeRequiresRequestOwner() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        vm.deal(request.bag, 4 ether);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, address(this)));
        _claimSingleNative(request.bag, payable(user), 4 ether);

        uint256 userBalanceBefore = user.balance;

        vm.prank(user);
        uint256 amountClaimed = _claimSingleNative(request.bag, payable(user), 4 ether)[0];

        assertEq(amountClaimed, 4 ether);
        assertEq(user.balance - userBalanceBefore, 4 ether);
        assertEq(request.bag.balance, 0);
    }

    function testRequestWithdrawalRevertsBelowMinimumAmount() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MinAmountRequestPolicy.AmountBelowMinimum.selector, minWithdrawalAmount - 1, minWithdrawalAmount
            )
        );
        vm.prank(user);
        manager.requestWithdrawal(minWithdrawalAmount - 1, user);
    }

    function testFuzzRequestWithdrawalRevertsBelowMinimumAmount(uint96 amount) public {
        amount = uint96(bound(amount, 1, minWithdrawalAmount - 1));

        vm.expectRevert(
            abi.encodeWithSelector(MinAmountRequestPolicy.AmountBelowMinimum.selector, amount, minWithdrawalAmount)
        );
        vm.prank(user);
        manager.requestWithdrawal(amount, user);
    }

    function testRequestWithdrawalRevertsForZeroReceiver() public {
        vm.expectRevert(WithdrawalRequest.ZeroAddress.selector);
        vm.prank(user);
        manager.requestWithdrawal(10 ether, address(0));
    }

    function testRequestsRevertsWhenRequestDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.RequestNotFound.selector, 123));
        manager.requests(123);
    }

    function testSetRequestPolicyRequiresConfigurationManagerRole() public {
        MinAmountRequestPolicy newRequestPolicy = new MinAmountRequestPolicy(2 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.CONFIGURATION_MANAGER_ROLE()
            )
        );
        vm.prank(user);
        manager.setRequestPolicy(address(newRequestPolicy));
    }

    function testSetRequestPolicyUpdatesPolicy() public {
        MinAmountRequestPolicy newRequestPolicy = new MinAmountRequestPolicy(2 ether);

        vm.expectEmit(false, false, false, true, address(manager));
        emit WithdrawalRequest.RequestPolicyUpdated(address(requestPolicy), address(newRequestPolicy));

        vm.prank(configurationManager);
        manager.setRequestPolicy(address(newRequestPolicy));

        assertEq(address(manager.requestPolicy()), address(newRequestPolicy));
    }

    function testSetRequestPolicyUpdatesMinimumValidation() public {
        MinAmountRequestPolicy newRequestPolicy = new MinAmountRequestPolicy(2 ether);

        vm.prank(configurationManager);
        manager.setRequestPolicy(address(newRequestPolicy));

        vm.expectRevert(abi.encodeWithSelector(MinAmountRequestPolicy.AmountBelowMinimum.selector, 1 ether, 2 ether));
        vm.prank(user);
        manager.requestWithdrawal(1 ether, user);
    }

    function testSetRequestPolicyRevertsForZeroAddress() public {
        vm.expectRevert(WithdrawalRequest.ZeroAddress.selector);
        vm.prank(configurationManager);
        manager.setRequestPolicy(address(0));
    }

    function testSetWithdrawerUpdatesWithdrawerAndApproval() public {
        BaseWithdrawer newWithdrawer = new BaseWithdrawer(address(ynToken), address(manager));

        vm.expectEmit(false, false, false, true, address(manager));
        emit WithdrawalRequest.WithdrawerUpdated(address(withdrawer), address(newWithdrawer));

        vm.prank(configurationManager);
        manager.setWithdrawer(address(newWithdrawer));

        assertEq(address(manager.withdrawer()), address(newWithdrawer));
        assertEq(ynToken.allowance(address(manager), address(withdrawer)), 0);
        assertEq(ynToken.allowance(address(manager), address(newWithdrawer)), type(uint256).max);
    }

    function testSetWithdrawerRequiresConfigurationManagerRole() public {
        BaseWithdrawer newWithdrawer = new BaseWithdrawer(address(ynToken), address(manager));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.CONFIGURATION_MANAGER_ROLE()
            )
        );
        vm.prank(user);
        manager.setWithdrawer(address(newWithdrawer));
    }

    function testSetWithdrawerRevertsForZeroAddress() public {
        vm.expectRevert(WithdrawalRequest.ZeroAddress.selector);
        vm.prank(configurationManager);
        manager.setWithdrawer(address(0));
    }

    function testBaseWithdrawerConstructorRevertsForZeroAddresses() public {
        vm.expectRevert(BaseWithdrawer.ZeroAddress.selector);
        new BaseWithdrawer(address(0), address(manager));

        vm.expectRevert(BaseWithdrawer.ZeroAddress.selector);
        new BaseWithdrawer(address(ynToken), address(0));
    }

    function testBaseWithdrawerRejectsUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(BaseWithdrawer.Unauthorized.selector, user));
        vm.prank(user);
        withdrawer.withdrawAsset(0, address(asset), 1 ether, user, address(manager));
    }

    function testBaseWithdrawerForwardsWithdrawalAndReturnsBurnedShares() public {
        ynToken.mint(address(manager), 2 ether);

        vm.prank(address(manager));
        uint256 sharesBurned = withdrawer.withdrawAsset(0, address(asset), 2 ether, receiver, address(manager));

        assertEq(sharesBurned, 2 ether);
        assertEq(asset.balanceOf(receiver), 2 ether);
        assertEq(ynToken.balanceOf(address(manager)), 0);
    }

    function testBaseWithdrawerConvertToAssetsUsesVaultRate() public view {
        assertEq(withdrawer.convertToAssets(1 ether), 1 ether);
    }

    function testConvertToAssets() public view {
        assertEq(viewer.convertToAssets(manager, address(asset), 0), 0);
        assertEq(viewer.convertToAssets(manager, address(asset), 10 ether), 10 ether);
    }

    function testConvertToAssetsAtRedemptionRateUsesConfiguredWithdrawer() public {
        assertEq(viewer.convertToAssetsAtRedemptionRate(manager, 1 ether), 1 ether);

        FixedRateWithdrawer fixedRateWithdrawer =
            new FixedRateWithdrawer(address(ynToken), address(manager), 0.5 ether, collector);

        vm.prank(configurationManager);
        manager.setWithdrawer(address(fixedRateWithdrawer));

        assertEq(fixedRateWithdrawer.convertToAssets(1 ether), 0.5 ether);
        assertEq(viewer.convertToAssetsAtRedemptionRate(manager, 1 ether), 0.5 ether);
        assertEq(viewer.convertToAssetsAtRedemptionRate(manager, 2 ether), 1 ether);
    }

    function testMinWithdrawalAmountUsesConfiguredRequestPolicy() public {
        assertEq(viewer.minWithdrawalAmount(manager), minWithdrawalAmount);

        MinAmountRequestPolicy newRequestPolicy = new MinAmountRequestPolicy(2 ether);

        vm.prank(configurationManager);
        manager.setRequestPolicy(address(newRequestPolicy));

        assertEq(viewer.minWithdrawalAmount(manager), 2 ether);
    }

    function testFuzzConvertToAssetsReturnsAssetsForShares(uint128 shares) public view {
        assertEq(viewer.convertToAssets(manager, address(asset), shares), shares);
    }

    function testPausePreventsRequestWithdrawal() public {
        vm.prank(pauser);
        manager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        manager.requestWithdrawal(10 ether, user);
    }

    function testUnpauseRestoresRequestWithdrawal() public {
        vm.prank(pauser);
        manager.pause();

        vm.prank(pauser);
        manager.unpause();

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        assertEq(id, 0);
        assertEq(manager.ownerOf(id), user);
    }

    function testPauseRequiresPauserRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.PAUSER_ROLE()
            )
        );
        vm.prank(user);
        manager.pause();
    }

    function testUnpauseRequiresPauserRole() public {
        vm.prank(pauser);
        manager.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.PAUSER_ROLE()
            )
        );
        vm.prank(user);
        manager.unpause();
    }

    function testPauseDoesNotPreventResolution() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(pauser);
        manager.pause();

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), 4 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(amountBurned, 4 ether);
        assertEq(request.amountLocked, 6 ether);
    }

    function testResolveWithdrawalRequestBurnsLockedTokenAndSubtractsBurnedAmount() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.assetsRedeemed.length, 0);

        vm.expectEmit(true, true, true, true, address(manager));
        emit WithdrawalRequest.WithdrawalRequestResolved(
            id, user, address(ynToken), address(asset), 4 ether, 4 ether, 6 ether
        );

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), 4 ether);

        assertEq(amountBurned, 4 ether);
        assertEq(ynToken.balanceOf(address(manager)), 6 ether);
        assertEq(asset.balanceOf(address(manager)), 0);
        request = manager.requests(id);
        assertEq(asset.balanceOf(request.bag), 4 ether);
        assertEq(asset.balanceOf(user), 0);
        assertEq(request.amountLocked, 6 ether);
        assertEq(request.assetsRedeemed.length, 1);
        assertEq(request.assetsRedeemed[0], address(asset));

        vm.prank(user);
        assertEq(_claimSingleERC20(request.bag, address(asset), user, 4 ether)[0], 4 ether);
        assertEq(asset.balanceOf(user), 4 ether);
        assertEq(asset.balanceOf(request.bag), 0);
    }

    function testResolveWithdrawalRequestTracksUniqueRedeemedAssets() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.startPrank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 4 ether);
        manager.resolveWithdrawalRequest(id, address(asset), 2 ether);
        manager.resolveWithdrawalRequest(id, address(secondAsset), 3 ether);
        vm.stopPrank();

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.assetsRedeemed.length, 2);
        assertEq(request.assetsRedeemed[0], address(asset));
        assertEq(request.assetsRedeemed[1], address(secondAsset));
        assertEq(request.amountLocked, 1 ether);
    }

    function testResolveWithdrawalRequestWithArraysResolvesMultipleAssets() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        address[] memory assets = new address[](2);
        assets[0] = address(asset);
        assets[1] = address(secondAsset);
        uint256[] memory assetAmounts = new uint256[](2);
        assetAmounts[0] = 4 ether;
        assetAmounts[1] = 3 ether;

        vm.prank(resolver);
        uint256[] memory amountsBurned = manager.resolveWithdrawalRequest(id, assets, assetAmounts);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(amountsBurned.length, 2);
        assertEq(amountsBurned[0], 4 ether);
        assertEq(amountsBurned[1], 3 ether);
        assertEq(request.amountLocked, 3 ether);
        assertEq(request.assetsRedeemed.length, 2);
        assertEq(request.assetsRedeemed[0], address(asset));
        assertEq(request.assetsRedeemed[1], address(secondAsset));
        assertEq(asset.balanceOf(request.bag), 4 ether);
        assertEq(secondAsset.balanceOf(request.bag), 3 ether);
    }

    function testResolveWithdrawalRequestWithArraysRevertsForLengthMismatch() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        address[] memory assets = new address[](2);
        assets[0] = address(asset);
        assets[1] = address(secondAsset);
        uint256[] memory assetAmounts = new uint256[](1);
        assetAmounts[0] = 4 ether;

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.ArrayLengthMismatch.selector, 2, 1));
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, assets, assetAmounts);
    }

    function testResolveWithdrawalRequestRevertsOnReentrancy() public {
        ReentrantResolveWithdrawer reentrantWithdrawer = new ReentrantResolveWithdrawer();
        reentrantWithdrawer.arm(manager, address(asset));

        vm.startPrank(admin);
        manager.grantRole(manager.RESOLVER_ROLE(), address(reentrantWithdrawer));
        vm.stopPrank();

        vm.prank(configurationManager);
        manager.setWithdrawer(address(reentrantWithdrawer));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 1 ether);
    }

    function testResolveWithdrawalRequestRevertsForZeroAsset() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(WithdrawalRequest.ZeroAddress.selector);
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(0), 1 ether);
    }

    function testResolveWithdrawalRequestRevertsForZeroAssets() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(WithdrawalRequest.ZeroAmount.selector);
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 0);
    }

    function testFixedRateWithdrawerRejectsNonDefaultAsset() public {
        FixedRateWithdrawer fixedRateWithdrawer =
            new FixedRateWithdrawer(address(ynToken), address(manager), 1 ether, collector);

        vm.prank(configurationManager);
        manager.setWithdrawer(address(fixedRateWithdrawer));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(abi.encodeWithSelector(FixedRateWithdrawer.InvalidAsset.selector, address(secondAsset)));
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(secondAsset), 1 ether);
    }

    function testFixedRateWithdrawerConstructorRevertsForInvalidParams() public {
        vm.expectRevert(FixedRateWithdrawer.InvalidRate.selector);
        new FixedRateWithdrawer(address(ynToken), address(manager), 0, collector);

        vm.expectRevert(BaseWithdrawer.ZeroAddress.selector);
        new FixedRateWithdrawer(address(ynToken), address(manager), 1 ether, address(0));
    }

    function testFixedRateWithdrawerReturnsActualBurnWhenRateIsBelowFixedRate() public {
        FixedRateWithdrawer fixedRateWithdrawer =
            new FixedRateWithdrawer(address(ynToken), address(manager), 1 ether, collector);

        vm.prank(configurationManager);
        manager.setWithdrawer(address(fixedRateWithdrawer));
        ynToken.setBurnMultiplier(2);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), 1 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(amountBurned, 2 ether);
        assertEq(request.amountLocked, 8 ether);
        assertEq(ynToken.balanceOf(collector), 0);
    }

    function testFixedRateWithdrawerAllowsDefaultAssetAtFixedRate() public {
        FixedRateWithdrawer fixedRateWithdrawer =
            new FixedRateWithdrawer(address(ynToken), address(manager), 1 ether, collector);

        vm.prank(configurationManager);
        manager.setWithdrawer(address(fixedRateWithdrawer));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), 1 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(amountBurned, 1 ether);
        assertEq(request.amountLocked, 9 ether);
        assertEq(asset.balanceOf(request.bag), 1 ether);
    }

    function testFixedRateWithdrawerTransfersSurplusSharesToCollector() public {
        FixedRateWithdrawer fixedRateWithdrawer =
            new FixedRateWithdrawer(address(ynToken), address(manager), 0.5 ether, collector);

        vm.prank(configurationManager);
        manager.setWithdrawer(address(fixedRateWithdrawer));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), 1 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(amountBurned, 2 ether);
        assertEq(request.amountLocked, 8 ether);
        assertEq(asset.balanceOf(request.bag), 1 ether);
        assertEq(ynToken.balanceOf(collector), 1 ether);
    }

    function testFuzzResolveWithdrawalRequestBurnsLockedTokenAndSubtractsBurnedAmount(
        uint96 lockedAmount,
        uint96 assets
    ) public {
        lockedAmount = uint96(bound(lockedAmount, minWithdrawalAmount, ynToken.balanceOf(user)));
        assets = uint96(bound(assets, 1, lockedAmount));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(lockedAmount, user);

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), assets);

        WithdrawalRequest.Request memory request = manager.requests(id);

        assertEq(amountBurned, assets);
        assertEq(request.amountLocked, lockedAmount - assets);
        assertEq(request.assetsRedeemed.length, 1);
        assertEq(request.assetsRedeemed[0], address(asset));
        assertEq(ynToken.balanceOf(address(manager)), lockedAmount - assets);
        assertEq(asset.balanceOf(request.bag), assets);
        assertEq(asset.balanceOf(address(manager)), 0);
        assertEq(asset.balanceOf(user), 0);
    }

    function testViewerMaxResolutionAssetsCanBeUsedToResolveLockedShares() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        uint256 maxAssets = viewer.maxResolutionAssets(manager, id, address(asset));

        assertEq(maxAssets, 10 ether);

        vm.expectEmit(true, true, true, true, address(manager));
        emit WithdrawalRequest.WithdrawalRequestResolved(
            id, user, address(ynToken), address(asset), 10 ether, 10 ether, 0
        );

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), maxAssets);

        assertEq(amountBurned, 10 ether);

        request = manager.requests(id);
        assertEq(asset.balanceOf(request.bag), 10 ether);
        assertEq(asset.balanceOf(user), 0);
        assertEq(request.amountLocked, 0);

        vm.prank(user);
        assertEq(_claimSingleERC20(request.bag, address(asset), user, 10 ether)[0], 10 ether);
        assertEq(asset.balanceOf(user), 10 ether);
    }

    function testFuzzViewerMaxResolutionAssetsCanBeUsedToResolveLockedShares(uint96 lockedAmount) public {
        lockedAmount = uint96(bound(lockedAmount, minWithdrawalAmount, ynToken.balanceOf(user)));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(lockedAmount, user);
        uint256 maxAssets = viewer.maxResolutionAssets(manager, id, address(asset));

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), maxAssets);

        WithdrawalRequest.Request memory request = manager.requests(id);

        assertEq(amountBurned, lockedAmount);
        assertEq(maxAssets, lockedAmount);
        assertEq(request.amountLocked, 0);
        assertEq(ynToken.balanceOf(address(manager)), 0);
        assertEq(asset.balanceOf(request.bag), lockedAmount);
    }

    function testResolveWithdrawalRequestRevertsWhenReturnedBurnAmountMismatchesBalanceDelta() public {
        ynToken.setReturnAmountOffset(100 ether);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.InvalidTokenBalanceChange.selector, 10 ether, 6 ether));
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 4 ether);
    }

    function testResolveWithdrawalRequestRevertsWhenAssetsWithdrawnMismatchExpected() public {
        ynToken.setTransferShortfall(1 ether);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.UnexpectedAssetsWithdrawn.selector, 4 ether, 3 ether));
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 4 ether);
    }

    function testResolveWithdrawalRequestRequiresResolverRole() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.RESOLVER_ROLE()
            )
        );
        vm.prank(user);
        manager.resolveWithdrawalRequest(id, address(asset), 1 ether);
    }

    function testResolveWithdrawalRequestRevertsWhenBurnExceedsLockedAmount() public {
        ynToken.mint(address(manager), 20 ether);
        ynToken.setBurnMultiplier(2);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawalRequest.InsufficientLockedAmount.selector, id, 10 ether, 12 ether)
        );
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 6 ether);
    }
}
