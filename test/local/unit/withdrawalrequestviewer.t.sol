// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {IBag} from "src/interface/IBag.sol";
import {MinAmountRequestPolicy} from "src/request-policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract ViewerVaultMock is ERC20 {
    using SafeERC20 for IERC20;

    address[] internal assetList;
    mapping(address asset => uint8 decimals_) internal assetDecimals;
    mapping(address asset => uint256 rate) internal assetRates;

    constructor() ERC20("ynToken", "ynT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setAssets(address[] memory assets_, uint8[] memory decimals_, uint256[] memory rates) external {
        delete assetList;
        for (uint256 i = 0; i < assets_.length; ++i) {
            assetList.push(assets_[i]);
            assetDecimals[assets_[i]] = decimals_[i];
            assetRates[assets_[i]] = rates[i];
        }
    }

    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        shares = assets;
        _burn(owner, shares);
        IERC20(asset_).safeTransfer(receiver, assets);
    }

    function totalBaseAssets() external view returns (uint256) {
        return totalSupply();
    }

    function provider() external view returns (address) {
        return address(this);
    }

    function getAsset(address asset_) external view returns (IVault.AssetParams memory) {
        return IVault.AssetParams({index: 0, active: true, decimals: assetDecimals[asset_]});
    }

    function getAssets() external view returns (address[] memory) {
        return assetList;
    }

    function getRate(address asset_) external view returns (uint256) {
        return assetRates[asset_];
    }

    function asset() external view returns (address) {
        return assetList[0];
    }

    function convertToAssets(uint256 shares) external pure returns (uint256 assets) {
        return shares;
    }
}

contract ViewerAssetMock is ERC20 {
    uint8 internal immutable decimals_;

    constructor(string memory name_, string memory symbol_, uint8 decimals__) ERC20(name_, symbol_) {
        decimals_ = decimals__;
    }

    function decimals() public view override returns (uint8) {
        return decimals_;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract WithdrawalRequestViewerTest is Test {
    WithdrawalRequest manager;
    WithdrawalRequestViewer viewer;
    ViewerVaultMock ynToken;
    ViewerAssetMock asset;
    ViewerAssetMock secondAsset;
    BeaconProxyFactory bagFactory;

    address admin = address(0xA11CE);
    address resolver = address(0xF0111);
    address configurationManager = address(0xC0F16);
    address pauser = address(0xAA05E);
    address user = address(0xB0B);
    address receiver = address(0xCA11);
    address other = address(0xCAFE);

    function setUp() public {
        ynToken = new ViewerVaultMock();
        asset = new ViewerAssetMock("Asset", "AST", 18);
        secondAsset = new ViewerAssetMock("Second", "SND", 6);
        viewer = new WithdrawalRequestViewer();

        Bag bagImplementation = new Bag();
        BeaconProxyFactory bagFactoryImplementation = new BeaconProxyFactory();
        bagFactory = BeaconProxyFactory(
            address(
                new ERC1967Proxy(
                    address(bagFactoryImplementation),
                    abi.encodeCall(BeaconProxyFactory.initialize, (address(bagImplementation), admin, admin, admin))
                )
            )
        );

        WithdrawalRequest implementation = new WithdrawalRequest();
        address predictedManager = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        BaseWithdrawer withdrawer = new BaseWithdrawer(address(ynToken), predictedManager);
        MinAmountRequestPolicy requestPolicy = new MinAmountRequestPolicy(1 ether);
        manager = WithdrawalRequest(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        WithdrawalRequest.initialize,
                        (
                            address(ynToken),
                            admin,
                            resolver,
                            configurationManager,
                            pauser,
                            address(bagFactory),
                            address(withdrawer),
                            address(requestPolicy)
                        )
                    )
                )
            )
        );

        bytes32 creatorRole = bagFactory.CREATOR_ROLE();
        vm.prank(admin);
        bagFactory.grantRole(creatorRole, address(manager));

        address[] memory assets = new address[](2);
        assets[0] = address(asset);
        assets[1] = address(secondAsset);
        uint8[] memory decimals_ = new uint8[](2);
        decimals_[0] = 18;
        decimals_[1] = 6;
        uint256[] memory rates = new uint256[](2);
        rates[0] = 1 ether;
        rates[1] = 2 ether;
        ynToken.setAssets(assets, decimals_, rates);

        ynToken.mint(user, 100 ether);
        asset.mint(address(ynToken), 100 ether);
        secondAsset.mint(address(ynToken), 100_000_000);

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

    function testGetRequestReturnsOwnerBagTokenAndAssetBalances() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 4 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        WithdrawalRequestViewer.RequestView memory view_ = viewer.getRequest(manager, id);

        assertEq(view_.id, id);
        assertEq(view_.owner, receiver);
        assertEq(view_.bag, request.bag);
        assertEq(view_.token, address(ynToken));
        assertEq(view_.amountLocked, 6 ether);
        assertEq(view_.rateAtRequest, 1 ether);
        assertEq(view_.tokenBalance, 6 ether);
        assertFalse(view_.isClaimable);
        assertFalse(view_.isClaimed);
        assertEq(view_.assetBalances.length, 1);
        assertEq(view_.assetBalances[0].asset, address(asset));
        assertEq(view_.assetBalances[0].balance, 4 ether);
        assertEq(manager.ownerOf(id), receiver);
    }

    function testGetRequestUsesRedeemedAssetsAfterVaultAssetListChanges() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 4 ether);

        address[] memory assets = new address[](0);
        uint8[] memory decimals_ = new uint8[](0);
        uint256[] memory rates = new uint256[](0);
        ynToken.setAssets(assets, decimals_, rates);

        WithdrawalRequestViewer.RequestView memory view_ = viewer.getRequest(manager, id);

        assertEq(view_.assetBalances.length, 1);
        assertEq(view_.assetBalances[0].asset, address(asset));
        assertEq(view_.assetBalances[0].balance, 4 ether);
        assertFalse(view_.isClaimed);
    }

    function testGetInProgressRequestsForOwnerReturnsCurrentOwnerRequests() public {
        vm.startPrank(user);
        uint256 completedId = manager.requestWithdrawal(10 ether, receiver);
        uint256 otherId = manager.requestWithdrawal(11 ether, other);
        uint256 transferredId = manager.requestWithdrawal(12 ether, receiver);
        vm.stopPrank();

        vm.prank(resolver);
        manager.resolveWithdrawalRequest(completedId, address(asset), 10 ether);

        vm.prank(receiver);
        manager.transferFrom(receiver, other, transferredId);

        WithdrawalRequestViewer.RequestView[] memory receiverRequests =
            viewer.getInProgressRequestsForOwner(manager, receiver);
        assertEq(receiverRequests.length, 1);
        assertEq(receiverRequests[0].id, completedId);
        assertEq(receiverRequests[0].owner, receiver);
        assertEq(receiverRequests[0].amountLocked, 0);
        assertTrue(receiverRequests[0].isClaimable);
        assertFalse(receiverRequests[0].isClaimed);
        assertEq(receiverRequests[0].assetBalances[0].balance, 10 ether);

        WithdrawalRequestViewer.RequestView[] memory otherRequests =
            viewer.getInProgressRequestsForOwner(manager, other);
        assertEq(otherRequests.length, 2);
        assertEq(otherRequests[0].id, otherId);
        assertEq(otherRequests[0].owner, other);
        assertEq(otherRequests[0].amountLocked, 11 ether);
        assertFalse(otherRequests[0].isClaimable);
        assertFalse(otherRequests[0].isClaimed);
        assertEq(otherRequests[1].id, transferredId);
        assertEq(otherRequests[1].owner, other);
        assertEq(otherRequests[1].amountLocked, 12 ether);
        assertFalse(otherRequests[1].isClaimable);
        assertFalse(otherRequests[1].isClaimed);
    }

    function testRequestIsClaimableUsesLockedTokenDustThreshold() public {
        uint256 dustThreshold = 10 ** ynToken.decimals() / 1e4;

        vm.startPrank(user);
        uint256 atThresholdId = manager.requestWithdrawal(10 ether, receiver);
        uint256 belowThresholdId = manager.requestWithdrawal(10 ether, receiver);
        vm.stopPrank();

        assertFalse(viewer.requestIsClaimable(manager, atThresholdId));
        assertFalse(viewer.requestIsClaimable(manager, belowThresholdId));

        vm.startPrank(resolver);
        manager.resolveWithdrawalRequest(atThresholdId, address(asset), 10 ether - dustThreshold);
        manager.resolveWithdrawalRequest(belowThresholdId, address(asset), 10 ether - dustThreshold + 1);
        vm.stopPrank();

        assertFalse(viewer.requestIsClaimable(manager, atThresholdId));
        assertTrue(viewer.requestIsClaimable(manager, belowThresholdId));
    }

    function testRequestIsClaimedRequiresAllBagAssetBalancesToBeZero() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertFalse(viewer.requestIsClaimed(manager, id));

        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 10 ether);

        assertFalse(viewer.requestIsClaimed(manager, id));

        vm.prank(receiver);
        assertEq(_claimSingleERC20(request.bag, address(asset), receiver, 10 ether)[0], 10 ether);

        assertTrue(viewer.requestIsClaimed(manager, id));
    }

    function testConvertToAssetsUsesVaultRateAndDecimals() public view {
        assertEq(viewer.convertToAssets(manager, address(asset), 10 ether), 10 ether);
        assertEq(viewer.convertToAssets(manager, address(secondAsset), 10 ether), 5_000_000);
    }

    function testMaxResolutionAssetsUsesCurrentAmountLocked() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver);

        assertEq(viewer.maxResolutionAssets(manager, id, address(asset)), 10 ether);

        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 4 ether);

        assertEq(viewer.maxResolutionAssets(manager, id, address(asset)), 6 ether);
    }

    function testViewerRevertsForMissingRequest() public {
        assertFalse(viewer.requestIsClaimable(manager, 123));
        assertFalse(viewer.requestIsClaimed(manager, 123));

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.RequestNotFound.selector, 123));
        viewer.getRequest(manager, 123);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.RequestNotFound.selector, 123));
        viewer.maxResolutionAssets(manager, 123, address(asset));
    }
}
