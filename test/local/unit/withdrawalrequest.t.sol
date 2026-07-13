// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IAccessControl} from "lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC721Enumerable} from "lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IBag} from "src/interface/IBag.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract MockWithdrawAssetVault is ERC20 {
    uint256 public burnMultiplier = 1;
    uint256 public returnAmountOffset;
    uint256 public transferShortfall;
    uint256 public processAccountingCalls;
    address[] internal assetList;

    constructor() ERC20("ynToken", "ynT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setBurnMultiplier(uint256 burnMultiplier_) external {
        burnMultiplier = burnMultiplier_;
    }

    function setReturnAmountOffset(uint256 returnAmountOffset_) external {
        returnAmountOffset = returnAmountOffset_;
    }

    function setTransferShortfall(uint256 transferShortfall_) external {
        transferShortfall = transferShortfall_;
    }

    function setAssets(address[] memory assets_) external {
        delete assetList;
        for (uint256 i = 0; i < assets_.length; ++i) {
            assetList.push(assets_[i]);
        }
    }

    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        shares = assets * burnMultiplier;
        _burn(owner, shares);
        ERC20(asset_).transfer(receiver, assets - transferShortfall);

        shares += returnAmountOffset;
    }

    function totalBaseAssets() external view returns (uint256) {
        return totalSupply();
    }

    function provider() external view returns (address) {
        return address(this);
    }

    function getAsset(address) external pure returns (IVault.AssetParams memory) {
        return IVault.AssetParams({index: 0, active: true, decimals: 18});
    }

    function getAssets() external view returns (address[] memory) {
        return assetList;
    }

    function getRate(address) external pure returns (uint256) {
        return 1 ether;
    }

    function processAccounting() external {
        processAccountingCalls++;
    }
}

contract WithdrawalAssetMock is ERC20 {
    constructor() ERC20("Asset", "AST") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract WithdrawalRequestTest is Test {
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    WithdrawalRequest manager;
    MockWithdrawAssetVault ynToken;
    WithdrawalAssetMock asset;
    WithdrawalAssetMock secondAsset;
    WithdrawalRequestViewer viewer;
    Bag bagImplementation;
    BeaconProxyFactory proxyFactoryImplementation;
    BeaconProxyFactory proxyFactory;

    address admin = address(0xA11CE);
    address fulfiller = address(0xF0111);
    address configurationManager = address(0xC0F16);
    address pauser = address(0xAA05E);
    address user = address(0xB0B);
    address receiver = address(0xCA11);
    uint256 minWithdrawalAmount = 1 ether;

    function setUp() public {
        ynToken = new MockWithdrawAssetVault();
        asset = new WithdrawalAssetMock();
        secondAsset = new WithdrawalAssetMock();
        viewer = new WithdrawalRequestViewer();
        bagImplementation = new Bag();
        proxyFactoryImplementation = new BeaconProxyFactory();
        ERC1967Proxy proxyFactoryProxy = new ERC1967Proxy(
            address(proxyFactoryImplementation),
            abi.encodeCall(BeaconProxyFactory.initialize, (address(bagImplementation), admin, admin, admin))
        );
        proxyFactory = BeaconProxyFactory(address(proxyFactoryProxy));

        WithdrawalRequest implementation = new WithdrawalRequest();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                WithdrawalRequest.initialize,
                (
                    address(ynToken),
                    admin,
                    fulfiller,
                    configurationManager,
                    pauser,
                    address(proxyFactory),
                    minWithdrawalAmount
                )
            )
        );
        manager = WithdrawalRequest(address(proxy));
        bytes32 creatorRole = proxyFactory.CREATOR_ROLE();
        vm.prank(admin);
        proxyFactory.grantRole(creatorRole, address(manager));

        ynToken.mint(user, 100 ether);
        asset.mint(address(ynToken), 100 ether);
        secondAsset.mint(address(ynToken), 100 ether);
        address[] memory assets = new address[](2);
        assets[0] = address(asset);
        assets[1] = address(secondAsset);
        ynToken.setAssets(assets);

        vm.prank(user);
        ynToken.approve(address(manager), type(uint256).max);
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

    function testRequestWithdrawalTransfersTokenAndRecordsRequest() public {
        vm.expectEmit(true, false, true, false, address(manager));
        emit WithdrawalRequest.WithdrawalRequested(0, user, address(ynToken), address(0), 10 ether);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        assertEq(id, 0);
        assertEq(manager.nextRequestId(), 1);
        assertEq(address(manager.proxyFactory()), address(proxyFactory));
        assertTrue(manager.requestExists(id));
        assertFalse(manager.requestExists(id + 1));
        assertEq(ynToken.balanceOf(user), 90 ether);
        assertEq(ynToken.balanceOf(address(manager)), 10 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertTrue(request.bag != address(0));
        assertEq(manager.ownerOf(id), user);
        assertEq(manager.name(), "MAX Vault Withdrawal Request");
        assertEq(manager.symbol(), "ynWREQ");
        assertTrue(manager.supportsInterface(type(IERC721Enumerable).interfaceId));
        assertEq(IBag(request.bag).ownerRegistry(), address(manager));
        assertEq(IBag(request.bag).id(), id);
        assertEq(request.amountLocked, 10 ether);
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
        assertEq(view_.tokenBalance, 10 ether);
        assertEq(view_.assetBalances.length, 0);
    }

    function testViewerReturnsBagAssetBalancesAfterFulfillment() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        vm.prank(fulfiller);
        manager.fulfillWithdrawalRequest(id, address(asset), 4 ether, true);

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

    function testProxyFactoryRequiresCreatorRole() public {
        bytes32 creatorRole = proxyFactory.CREATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, creatorRole)
        );
        vm.prank(user);
        proxyFactory.create(abi.encodeCall(IBag.initialize, (address(manager), 1)));
    }

    function testProxyFactoryUpgradesImplementation() public {
        Bag newImplementation = new Bag();

        vm.prank(admin);
        proxyFactory.upgradeImplementation(address(newImplementation));

        assertEq(proxyFactory.implementation(), address(newImplementation));
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

    function testBagClaimAllowsApprovedRequestOperator() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        asset.mint(request.bag, 4 ether);

        vm.prank(user);
        manager.approve(receiver, id);

        assertTrue(manager.isAuthorized(receiver, id));

        vm.prank(receiver);
        uint256 amountClaimed = _claimSingleERC20(request.bag, address(asset), receiver, 4 ether)[0];

        assertEq(amountClaimed, 4 ether);
        assertEq(asset.balanceOf(receiver), 4 ether);
        assertEq(asset.balanceOf(request.bag), 0);
    }

    function testBagClaimAllowsApprovedForAllRequestOperator() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        asset.mint(request.bag, 4 ether);

        vm.prank(user);
        manager.setApprovalForAll(receiver, true);

        assertTrue(manager.isAuthorized(receiver, id));

        vm.prank(receiver);
        uint256 amountClaimed = _claimSingleERC20(request.bag, address(asset), receiver, 4 ether)[0];

        assertEq(amountClaimed, 4 ether);
        assertEq(asset.balanceOf(receiver), 4 ether);
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
                WithdrawalRequest.AmountBelowMinimum.selector, minWithdrawalAmount - 1, minWithdrawalAmount
            )
        );
        vm.prank(user);
        manager.requestWithdrawal(minWithdrawalAmount - 1, user);
    }

    function testFuzzRequestWithdrawalRevertsBelowMinimumAmount(uint96 amount) public {
        amount = uint96(bound(amount, 1, minWithdrawalAmount - 1));

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawalRequest.AmountBelowMinimum.selector, amount, minWithdrawalAmount)
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

    function testSetMinWithdrawalAmountRequiresConfigurationManagerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.CONFIGURATION_MANAGER_ROLE()
            )
        );
        vm.prank(user);
        manager.setMinWithdrawalAmount(2 ether);
    }

    function testSetMinWithdrawalAmountUpdatesMinimum() public {
        vm.expectEmit(true, true, true, true, address(manager));
        emit WithdrawalRequest.MinWithdrawalAmountUpdated(minWithdrawalAmount, 2 ether);

        vm.prank(configurationManager);
        manager.setMinWithdrawalAmount(2 ether);

        assertEq(manager.minWithdrawalAmount(), 2 ether);
    }

    function testFuzzSetMinWithdrawalAmountUpdatesMinimum(uint128 newMinWithdrawalAmount) public {
        vm.prank(configurationManager);
        manager.setMinWithdrawalAmount(newMinWithdrawalAmount);

        assertEq(manager.minWithdrawalAmount(), newMinWithdrawalAmount);
    }

    function testConvertToAssets() public view {
        assertEq(viewer.convertToAssets(manager, address(asset), 0), 0);
        assertEq(viewer.convertToAssets(manager, address(asset), 10 ether), 10 ether);
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

    function testPauseRequiresPauserRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.PAUSER_ROLE()
            )
        );
        vm.prank(user);
        manager.pause();
    }

    function testFulfillWithdrawalRequestBurnsLockedTokenAndSubtractsBurnedAmount() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.assetsRedeemed.length, 0);

        vm.expectEmit(true, true, true, true, address(manager));
        emit WithdrawalRequest.WithdrawalRequestFulfilled(
            id, user, address(ynToken), address(asset), 4 ether, 4 ether, 6 ether
        );

        vm.prank(fulfiller);
        uint256 amountBurned = manager.fulfillWithdrawalRequest(id, address(asset), 4 ether, true);

        assertEq(amountBurned, 4 ether);
        assertEq(ynToken.balanceOf(address(manager)), 6 ether);
        assertEq(asset.balanceOf(address(manager)), 0);
        assertEq(ynToken.processAccountingCalls(), 1);

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

    function testFulfillWithdrawalRequestTracksUniqueRedeemedAssets() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.startPrank(fulfiller);
        manager.fulfillWithdrawalRequest(id, address(asset), 4 ether, true);
        manager.fulfillWithdrawalRequest(id, address(asset), 2 ether, true);
        manager.fulfillWithdrawalRequest(id, address(secondAsset), 3 ether, true);
        vm.stopPrank();

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.assetsRedeemed.length, 2);
        assertEq(request.assetsRedeemed[0], address(asset));
        assertEq(request.assetsRedeemed[1], address(secondAsset));
        assertEq(request.amountLocked, 1 ether);
    }

    function testFulfillWithdrawalRequestCanSkipProcessAccounting() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(fulfiller);
        uint256 amountBurned = manager.fulfillWithdrawalRequest(id, address(asset), 4 ether, false);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(amountBurned, 4 ether);
        assertEq(request.amountLocked, 6 ether);
        assertEq(asset.balanceOf(request.bag), 4 ether);
        assertEq(ynToken.processAccountingCalls(), 0);
    }

    function testFuzzFulfillWithdrawalRequestBurnsLockedTokenAndSubtractsBurnedAmount(
        uint96 lockedAmount,
        uint96 assets
    ) public {
        lockedAmount = uint96(bound(lockedAmount, minWithdrawalAmount, ynToken.balanceOf(user)));
        assets = uint96(bound(assets, 1, lockedAmount));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(lockedAmount, user);

        vm.prank(fulfiller);
        uint256 amountBurned = manager.fulfillWithdrawalRequest(id, address(asset), assets, true);

        WithdrawalRequest.Request memory request = manager.requests(id);

        assertEq(amountBurned, assets);
        assertEq(request.amountLocked, lockedAmount - assets);
        assertEq(request.assetsRedeemed.length, 1);
        assertEq(request.assetsRedeemed[0], address(asset));
        assertEq(ynToken.balanceOf(address(manager)), lockedAmount - assets);
        assertEq(asset.balanceOf(request.bag), assets);
        assertEq(asset.balanceOf(address(manager)), 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(ynToken.processAccountingCalls(), 1);
    }

    function testViewerMaxFulfillmentAssetsCanBeUsedToFulfillLockedShares() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        uint256 maxAssets = viewer.maxFulfillmentAssets(manager, id, address(asset));

        assertEq(maxAssets, 10 ether);

        vm.expectEmit(true, true, true, true, address(manager));
        emit WithdrawalRequest.WithdrawalRequestFulfilled(
            id, user, address(ynToken), address(asset), 10 ether, 10 ether, 0
        );

        vm.prank(fulfiller);
        uint256 amountBurned = manager.fulfillWithdrawalRequest(id, address(asset), maxAssets, true);

        assertEq(amountBurned, 10 ether);

        request = manager.requests(id);
        assertEq(asset.balanceOf(request.bag), 10 ether);
        assertEq(asset.balanceOf(user), 0);
        assertEq(request.amountLocked, 0);

        vm.prank(user);
        assertEq(_claimSingleERC20(request.bag, address(asset), user, 10 ether)[0], 10 ether);
        assertEq(asset.balanceOf(user), 10 ether);
    }

    function testFuzzViewerMaxFulfillmentAssetsCanBeUsedToFulfillLockedShares(uint96 lockedAmount) public {
        lockedAmount = uint96(bound(lockedAmount, minWithdrawalAmount, ynToken.balanceOf(user)));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(lockedAmount, user);
        uint256 maxAssets = viewer.maxFulfillmentAssets(manager, id, address(asset));

        vm.prank(fulfiller);
        uint256 amountBurned = manager.fulfillWithdrawalRequest(id, address(asset), maxAssets, true);

        WithdrawalRequest.Request memory request = manager.requests(id);

        assertEq(amountBurned, lockedAmount);
        assertEq(maxAssets, lockedAmount);
        assertEq(request.amountLocked, 0);
        assertEq(ynToken.balanceOf(address(manager)), 0);
        assertEq(asset.balanceOf(request.bag), lockedAmount);
        assertEq(ynToken.processAccountingCalls(), 1);
    }

    function testFulfillWithdrawalRequestRevertsWhenReturnedBurnAmountMismatchesBalanceDelta() public {
        ynToken.setReturnAmountOffset(100 ether);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.InvalidTokenBalanceChange.selector, 10 ether, 6 ether));
        vm.prank(fulfiller);
        manager.fulfillWithdrawalRequest(id, address(asset), 4 ether, true);
    }

    function testFulfillWithdrawalRequestRevertsWhenAssetsWithdrawnMismatchExpected() public {
        ynToken.setTransferShortfall(1 ether);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.UnexpectedAssetsWithdrawn.selector, 4 ether, 3 ether));
        vm.prank(fulfiller);
        manager.fulfillWithdrawalRequest(id, address(asset), 4 ether, true);
    }

    function testFulfillWithdrawalRequestRequiresFulfillerRole() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.FULFILLER_ROLE()
            )
        );
        vm.prank(user);
        manager.fulfillWithdrawalRequest(id, address(asset), 1 ether, true);
    }

    function testFulfillWithdrawalRequestRevertsWhenBurnExceedsLockedAmount() public {
        ynToken.mint(address(manager), 20 ether);
        ynToken.setBurnMultiplier(2);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawalRequest.InsufficientLockedAmount.selector, id, 10 ether, 12 ether)
        );
        vm.prank(fulfiller);
        manager.fulfillWithdrawalRequest(id, address(asset), 6 ether, true);
    }
}
