// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAccessControl} from "lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Enumerable} from "lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {IBag} from "src/interface/IBag.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";
import {Bag} from "src/Bag.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";
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

contract DrainingWithdrawer is IWithdrawer {
    using SafeERC20 for IERC20;

    IERC20 internal immutable token;

    constructor(address token_) {
        token = IERC20(token_);
    }

    function drain(address owner, address recipient, uint256 amount) external {
        token.safeTransferFrom(owner, recipient, amount);
    }

    function withdrawAsset(uint256, address, uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        return 0;
    }
}

interface IRequestRateWithdrawerVault is IERC20 {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/// @notice Hypothetical test-only withdrawer that charges each request at its recorded request-time rate.
contract RequestRateWithdrawer is IWithdrawer {
    using Math for uint256;
    using SafeERC20 for IRequestRateWithdrawerVault;

    WithdrawalRequest internal immutable manager;
    IRequestRateWithdrawerVault internal immutable token;
    address internal immutable collector;

    error Unauthorized(address caller);
    error InvalidAsset(address asset);

    constructor(address manager_, address token_, address collector_) {
        manager = WithdrawalRequest(manager_);
        token = IRequestRateWithdrawerVault(token_);
        collector = collector_;
    }

    function withdrawAsset(uint256 requestId, address asset, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        if (msg.sender != address(manager)) revert Unauthorized(msg.sender);
        if (asset != token.asset()) revert InvalidAsset(asset);

        WithdrawalRequest.Request memory request = manager.requests(requestId);
        uint256 sharesAtRequestRate = assets.mulDiv(10 ** token.decimals(), request.rateAtRequest, Math.Rounding.Ceil);

        uint256 sharesBurned = token.withdrawAsset(asset, assets, receiver, owner);
        if (sharesAtRequestRate <= sharesBurned) return sharesBurned;

        token.safeTransferFrom(owner, collector, sharesAtRequestRate - sharesBurned);
        return sharesAtRequestRate;
    }

    function convertToAssets(uint256 shares) external view returns (uint256 assets) {
        return token.convertToAssets(shares);
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
        address requestPolicy_,
        uint256 maxDataLength_
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            WithdrawalRequest.initialize,
            (
                token_,
                admin_,
                resolver_,
                configurationManager_,
                pauser_,
                bagFactory_,
                withdrawer_,
                requestPolicy_,
                maxDataLength_
            )
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
        address requestPolicy_,
        uint256 maxDataLength_
    ) internal {
        WithdrawalRequest implementation = new WithdrawalRequest();

        vm.expectRevert(WithdrawalRequest.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(implementation),
            admin_,
            _defaultInitializeCall(
                token_,
                admin_,
                resolver_,
                configurationManager_,
                pauser_,
                bagFactory_,
                withdrawer_,
                requestPolicy_,
                maxDataLength_
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
            address(requestPolicy),
            maxDataLength
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
            address(requestPolicy),
            maxDataLength
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
            address(requestPolicy),
            maxDataLength
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            address(0),
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy),
            maxDataLength
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            address(0),
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy),
            maxDataLength
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            address(0),
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy),
            maxDataLength
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            address(0),
            address(bagFactory),
            address(withdrawer),
            address(requestPolicy),
            maxDataLength
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(0),
            address(withdrawer),
            address(requestPolicy),
            maxDataLength
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(0),
            address(requestPolicy),
            maxDataLength
        );
        _expectInitializeRevertsForZeroAddress(
            address(ynToken),
            admin,
            resolver,
            configurationManager,
            pauser,
            address(bagFactory),
            address(withdrawer),
            address(0),
            maxDataLength
        );
    }

    function testRequestWithdrawalTransfersTokenAndRecordsRequest() public {
        vm.expectEmit(true, false, true, false, address(manager));
        emit WithdrawalRequest.WithdrawalRequested(0, user, address(ynToken), address(0), 10 ether, "");

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
        assertEq(manager.maxDataLength(), maxDataLength);
        assertEq(ynToken.allowance(address(manager), address(withdrawer)), 0);
        assertTrue(manager.supportsInterface(type(IERC721Enumerable).interfaceId));
        assertEq(IBag(request.bag).ownerRegistry(), address(manager));
        assertEq(IBag(request.bag).id(), id);
        assertEq(request.amountLocked, 10 ether);
        assertEq(request.rateAtRequest, 1 ether);
        assertEq(request.data.length, 0);
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

    function testRequestWithdrawalStoresBoundedData() public {
        bytes memory data = abi.encodePacked("integration-reference", uint256(42));

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, data);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(keccak256(request.data), keccak256(data));
    }

    function testRequestWithdrawalEmitsData() public {
        bytes memory data = abi.encodePacked("event-data");

        vm.recordLogs();
        vm.prank(user);
        manager.requestWithdrawal(10 ether, user, data);

        bytes32 eventSignature = keccak256("WithdrawalRequested(uint256,address,address,address,uint256,bytes)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;

        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].emitter != address(manager) || entries[i].topics[0] != eventSignature) continue;

            (address bag, uint256 amountLocked, bytes memory emittedData) =
                abi.decode(entries[i].data, (address, uint256, bytes));

            assertEq(uint256(entries[i].topics[1]), 0);
            assertEq(address(uint160(uint256(entries[i].topics[2]))), user);
            assertEq(address(uint160(uint256(entries[i].topics[3]))), address(ynToken));
            assertTrue(bag != address(0));
            assertEq(amountLocked, 10 ether);
            assertEq(keccak256(emittedData), keccak256(data));
            found = true;
        }

        assertTrue(found);
    }

    function testRequestWithdrawalAllowsMaxLengthData() public {
        bytes memory data = new bytes(manager.maxDataLength());
        data[0] = 0x01;
        data[data.length - 1] = 0x02;

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, data);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.data.length, manager.maxDataLength());
        assertEq(keccak256(request.data), keccak256(data));
    }

    function testRequestWithdrawalRevertsWhenDataIsTooLong() public {
        bytes memory data = new bytes(manager.maxDataLength() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawalRequest.DataTooLong.selector, data.length, manager.maxDataLength())
        );
        vm.prank(user);
        manager.requestWithdrawal(10 ether, user, data);
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
        bytes memory data = abi.encodePacked("ui-data");

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, receiver, data);

        WithdrawalRequest.Request memory request = manager.requests(id);
        WithdrawalRequestViewer.RequestView memory view_ = viewer.getRequest(manager, id);

        assertEq(view_.owner, receiver);
        assertEq(view_.bag, request.bag);
        assertEq(view_.token, address(ynToken));
        assertEq(view_.amountLocked, 10 ether);
        assertEq(view_.rateAtRequest, 1 ether);
        assertEq(keccak256(view_.data), keccak256(data));
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

        assertEq(manager.getApproved(id), receiver);

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

        assertTrue(manager.isApprovedForAll(user, receiver));

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

    function testBurnRequiresRequestOwner() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.NotRequestOwner.selector, receiver));
        vm.prank(receiver);
        manager.burn(id);
    }

    function testBurnRevertsWhenLockedAmountRemaining() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.RequestNotBurnable.selector, id));
        vm.prank(user);
        manager.burn(id);
    }

    function testBurnRevertsWhenBagAssetBalanceRemaining() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 10 ether);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.RequestNotBurnable.selector, id));
        vm.prank(user);
        manager.burn(id);
    }

    function testBurnRemovesClaimedRequestAndNFT() public {
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 10 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);

        vm.prank(user);
        assertEq(_claimSingleERC20(request.bag, address(asset), user, 10 ether)[0], 10 ether);

        vm.expectEmit(true, true, true, true, address(manager));
        emit WithdrawalRequest.WithdrawalRequestBurned(id, user, request.bag);

        vm.prank(user);
        manager.burn(id);

        assertFalse(manager.requestExists(id));
        assertEq(manager.balanceOf(user), 0);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.RequestNotFound.selector, id));
        manager.requests(id);

        vm.expectRevert();
        manager.ownerOf(id);
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

    function testSetMaxDataLengthRequiresConfigurationManagerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, manager.CONFIGURATION_MANAGER_ROLE()
            )
        );
        vm.prank(user);
        manager.setMaxDataLength(64);
    }

    function testSetMaxDataLengthUpdatesLimitAndEmits() public {
        vm.expectEmit(false, false, false, true, address(manager));
        emit WithdrawalRequest.MaxDataLengthUpdated(maxDataLength, 64);

        vm.prank(configurationManager);
        manager.setMaxDataLength(64);

        assertEq(manager.maxDataLength(), 64);
    }

    function testSetMaxDataLengthUpdatesRequestValidation() public {
        vm.prank(configurationManager);
        manager.setMaxDataLength(4);

        bytes memory tooLong = new bytes(5);
        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.DataTooLong.selector, tooLong.length, 4));
        vm.prank(user);
        manager.requestWithdrawal(10 ether, user, tooLong);

        bytes memory allowed = new bytes(4);
        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, allowed);

        assertEq(manager.requests(id).data.length, 4);
    }

    function testSetMaxDataLengthCanDisableNonEmptyData() public {
        vm.prank(configurationManager);
        manager.setMaxDataLength(0);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.DataTooLong.selector, 1, 0));
        vm.prank(user);
        manager.requestWithdrawal(10 ether, user, hex"01");

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        assertEq(manager.requests(id).data.length, 0);
    }

    function testSetWithdrawerUpdatesWithdrawerAndRevokesOldApproval() public {
        BaseWithdrawer newWithdrawer = new BaseWithdrawer(address(ynToken), address(manager));

        vm.expectEmit(false, false, false, true, address(manager));
        emit WithdrawalRequest.WithdrawerUpdated(address(withdrawer), address(newWithdrawer));

        vm.prank(configurationManager);
        manager.setWithdrawer(address(newWithdrawer));

        assertEq(address(manager.withdrawer()), address(newWithdrawer));
        assertEq(ynToken.allowance(address(manager), address(withdrawer)), 0);
        assertEq(ynToken.allowance(address(manager), address(newWithdrawer)), 0);
    }

    function testConfiguredWithdrawerCannotDrainLockedSharesOutsideResolution() public {
        DrainingWithdrawer drainingWithdrawer = new DrainingWithdrawer(address(ynToken));

        vm.prank(configurationManager);
        manager.setWithdrawer(address(drainingWithdrawer));

        vm.prank(user);
        manager.requestWithdrawal(10 ether, user);

        assertEq(ynToken.allowance(address(manager), address(drainingWithdrawer)), 0);

        vm.expectRevert();
        drainingWithdrawer.drain(address(manager), collector, 10 ether);

        assertEq(ynToken.balanceOf(address(manager)), 10 ether);
        assertEq(ynToken.balanceOf(collector), 0);
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
        assertEq(ynToken.allowance(address(manager), address(withdrawer)), 0);
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

    function testBaseWithdrawerResolvesYnTokenIntoBagWithoutBurning() public {
        uint256 totalSupplyBefore = ynToken.totalSupply();

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);

        // The resolved asset is the yn-token itself, delivered in kind rather than burned.
        vm.expectEmit(true, true, true, true, address(manager));
        emit WithdrawalRequest.WithdrawalRequestResolved(
            id, user, address(ynToken), address(ynToken), 4 ether, 4 ether, 6 ether
        );

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(ynToken), 4 ether);

        request = manager.requests(id);

        // Nothing was burned: total supply is unchanged, the shares just moved into the bag.
        assertEq(ynToken.totalSupply(), totalSupplyBefore);
        assertEq(amountBurned, 4 ether);
        assertEq(request.amountLocked, 6 ether);
        assertEq(ynToken.balanceOf(address(manager)), 6 ether);
        assertEq(ynToken.balanceOf(request.bag), 4 ether);
        assertEq(request.assetsRedeemed.length, 1);
        assertEq(request.assetsRedeemed[0], address(ynToken));

        // The owner claims the yn-token shares straight out of the bag.
        vm.prank(user);
        assertEq(_claimSingleERC20(request.bag, address(ynToken), user, 4 ether)[0], 4 ether);
        assertEq(ynToken.balanceOf(user), 94 ether);
        assertEq(ynToken.balanceOf(request.bag), 0);
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

    function testRequestRateWithdrawerChargesRateRecordedAtRequestTime() public {
        RequestRateWithdrawer requestRateWithdrawer =
            new RequestRateWithdrawer(address(manager), address(ynToken), collector);

        vm.prank(configurationManager);
        manager.setWithdrawer(address(requestRateWithdrawer));

        ynToken.setConvertToAssetsRate(0.5 ether);

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.rateAtRequest, 0.5 ether);

        ynToken.setConvertToAssetsRate(1 ether);

        vm.prank(resolver);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, address(asset), 1 ether);

        request = manager.requests(id);
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
