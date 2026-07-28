// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IBag} from "src/interface/IBag.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {SetupWithdrawalRequest} from "test/local/unit/helpers/SetupWithdrawalRequest.sol";

/// @notice Test-only withdrawer used by DemoInOrderResolver. It supports normal vault asset withdrawal
/// and cancellation by moving the locked yn-token itself into the request bag.
contract DemoResolverWithdrawer is IWithdrawer {
    using SafeERC20 for IERC20;

    IVault internal immutable token;
    address internal immutable withdrawalRequest;

    error Unauthorized(address caller);

    constructor(address token_, address withdrawalRequest_) {
        token = IVault(token_);
        withdrawalRequest = withdrawalRequest_;
    }

    function withdrawAsset(uint256, address asset, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        if (msg.sender != withdrawalRequest) revert Unauthorized(msg.sender);

        if (asset == address(token)) {
            IERC20(address(token)).safeTransferFrom(owner, receiver, assets);
            return assets;
        }

        return token.withdrawAsset(asset, assets, receiver, owner);
    }

    function convertToAssets(uint256 shares) external view returns (uint256 assets) {
        return token.convertToAssets(shares);
    }
}

/// @notice Demo policy resolver that processes request ids in order and treats version-0 request data
/// as `abi.encode(uint8(0), uint256(deadline))`.
contract DemoInOrderResolver {
    WithdrawalRequest public immutable manager;
    address public immutable cancellationAsset;
    uint256 public nextRequestId;

    error DeadlineExpired(uint256 deadline);
    error DeadlineNotExpired(uint256 deadline);
    error UnexpectedRequest(uint256 expected, uint256 actual);
    error UnsupportedDataVersion(uint8 version);

    constructor(WithdrawalRequest manager_) {
        manager = manager_;
        cancellationAsset = address(manager_.token());
    }

    function resolve(uint256 id, address asset, uint256 assets) external returns (uint256 amountBurned) {
        _requireNext(id);

        uint256 deadline = deadlineOf(id);
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);

        amountBurned = manager.resolveWithdrawalRequest(id, asset, assets);
        _advanceIfComplete(id);
    }

    function cancelExpired(uint256 id) external returns (uint256 amountBurned) {
        _requireNext(id);

        uint256 deadline = deadlineOf(id);
        if (block.timestamp <= deadline) revert DeadlineNotExpired(deadline);

        WithdrawalRequest.Request memory request = manager.requests(id);
        amountBurned = manager.resolveWithdrawalRequest(id, cancellationAsset, request.amountLocked);
        _advanceIfComplete(id);
    }

    function deadlineOf(uint256 id) public view returns (uint256 deadline) {
        WithdrawalRequest.Request memory request = manager.requests(id);
        (uint8 version, uint256 decodedDeadline) = abi.decode(request.data, (uint8, uint256));
        if (version != 0) revert UnsupportedDataVersion(version);
        return decodedDeadline;
    }

    function _requireNext(uint256 id) internal view {
        if (id != nextRequestId) revert UnexpectedRequest(nextRequestId, id);
    }

    function _advanceIfComplete(uint256 id) internal {
        WithdrawalRequest.Request memory request = manager.requests(id);
        if (request.amountLocked == 0) nextRequestId = id + 1;
    }
}

contract DemoInOrderResolverTest is SetupWithdrawalRequest {
    function setUp() public {
        setUpWithdrawalRequest();
    }

    function testProcessesRequestsInOrder() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(user);
        uint256 firstId = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));
        uint256 secondId = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(DemoInOrderResolver.UnexpectedRequest.selector, firstId, secondId));
        demoResolver.resolve(secondId, address(asset), 1 ether);

        assertEq(demoResolver.resolve(firstId, address(asset), 4 ether), 4 ether);
        assertEq(demoResolver.nextRequestId(), firstId);

        vm.expectRevert(abi.encodeWithSelector(DemoInOrderResolver.UnexpectedRequest.selector, firstId, secondId));
        demoResolver.resolve(secondId, address(asset), 1 ether);

        assertEq(demoResolver.resolve(firstId, address(asset), 6 ether), 6 ether);
        assertEq(demoResolver.nextRequestId(), secondId);

        assertEq(demoResolver.resolve(secondId, address(asset), 10 ether), 10 ether);
        assertEq(demoResolver.nextRequestId(), secondId + 1);
    }

    function testAllowsResolutionAtExactDeadline() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));

        vm.warp(deadline);
        assertEq(demoResolver.resolve(id, address(asset), 10 ether), 10 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.amountLocked, 0);
        assertEq(asset.balanceOf(request.bag), 10 ether);
        assertEq(demoResolver.nextRequestId(), id + 1);
    }

    function testRejectsNormalResolutionAfterDeadline() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(DemoInOrderResolver.DeadlineExpired.selector, deadline));
        demoResolver.resolve(id, address(asset), 1 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.amountLocked, 10 ether);
        assertEq(asset.balanceOf(request.bag), 0);
        assertEq(demoResolver.nextRequestId(), id);
    }

    function testCancelsExpiredRequestByEjectingLockedSharesToBag() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));

        vm.expectRevert(abi.encodeWithSelector(DemoInOrderResolver.DeadlineNotExpired.selector, deadline));
        demoResolver.cancelExpired(id);

        vm.warp(deadline + 1);
        assertEq(demoResolver.cancelExpired(id), 10 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.amountLocked, 0);
        assertEq(ynToken.balanceOf(address(manager)), 0);
        assertEq(ynToken.balanceOf(request.bag), 10 ether);
        assertEq(demoResolver.nextRequestId(), id + 1);

        vm.prank(user);
        assertEq(_claimSingleERC20(request.bag, address(ynToken), user, 10 ether)[0], 10 ether);
        assertEq(ynToken.balanceOf(user), 100 ether);
    }

    function testCancelAfterPartialResolutionEjectsOnlyRemainingShares() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));

        assertEq(demoResolver.resolve(id, address(asset), 4 ether), 4 ether);
        assertEq(demoResolver.nextRequestId(), id);

        vm.warp(deadline + 1);
        assertEq(demoResolver.cancelExpired(id), 6 ether);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.amountLocked, 0);
        assertEq(asset.balanceOf(request.bag), 4 ether);
        assertEq(ynToken.balanceOf(request.bag), 6 ether);
        assertEq(demoResolver.nextRequestId(), id + 1);
    }

    function testCancelAlsoProcessesRequestsInOrder() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(user);
        uint256 firstId = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));
        uint256 secondId = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));
        vm.stopPrank();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(DemoInOrderResolver.UnexpectedRequest.selector, firstId, secondId));
        demoResolver.cancelExpired(secondId);

        assertEq(demoResolver.cancelExpired(firstId), 10 ether);
        assertEq(demoResolver.nextRequestId(), secondId);
        assertEq(demoResolver.cancelExpired(secondId), 10 ether);
        assertEq(demoResolver.nextRequestId(), secondId + 1);
    }

    function testCancelRecordsYnTokenAsRedeemedAssetSoRequestCannotBurnBeforeClaim() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));

        vm.warp(deadline + 1);
        demoResolver.cancelExpired(id);

        WithdrawalRequest.Request memory request = manager.requests(id);
        assertEq(request.assetsRedeemed.length, 1);
        assertEq(request.assetsRedeemed[0], address(ynToken));

        vm.expectRevert(abi.encodeWithSelector(WithdrawalRequest.RequestNotBurnable.selector, id));
        vm.prank(user);
        manager.burn(id);

        vm.prank(user);
        _claimSingleERC20(request.bag, address(ynToken), user, 10 ether);

        vm.prank(user);
        manager.burn(id);
        assertFalse(manager.requestExists(id));
    }

    function testRejectsUnsupportedDataVersion() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(1), block.timestamp + 1 days));

        vm.expectRevert(abi.encodeWithSelector(DemoInOrderResolver.UnsupportedDataVersion.selector, uint8(1)));
        demoResolver.resolve(id, address(asset), 1 ether);
    }

    function testRejectsMalformedData() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, hex"00");

        vm.expectRevert();
        demoResolver.resolve(id, address(asset), 1 ether);
    }

    function testOldResolverRoleCannotBypassDemoResolver() public {
        DemoInOrderResolver demoResolver = _installDemoResolver();
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(user);
        uint256 id = manager.requestWithdrawal(10 ether, user, abi.encode(uint8(0), deadline));

        vm.expectRevert();
        vm.prank(resolver);
        manager.resolveWithdrawalRequest(id, address(asset), 1 ether);

        assertEq(demoResolver.resolve(id, address(asset), 10 ether), 10 ether);
    }

    function testDemoWithdrawerRejectsDirectCalls() public {
        DemoResolverWithdrawer demoWithdrawer = new DemoResolverWithdrawer(address(ynToken), address(manager));

        vm.expectRevert(abi.encodeWithSelector(DemoResolverWithdrawer.Unauthorized.selector, user));
        vm.prank(user);
        demoWithdrawer.withdrawAsset(0, address(asset), 1 ether, user, address(manager));
    }

    function _installDemoResolver() internal returns (DemoInOrderResolver demoResolver) {
        demoResolver = new DemoInOrderResolver(manager);
        DemoResolverWithdrawer demoWithdrawer = new DemoResolverWithdrawer(address(ynToken), address(manager));
        _authorizeAssetWithdrawer(address(demoWithdrawer));

        vm.prank(configurationManager);
        manager.setWithdrawer(address(demoWithdrawer));

        vm.startPrank(admin);
        manager.grantRole(manager.RESOLVER_ROLE(), address(demoResolver));
        manager.revokeRole(manager.RESOLVER_ROLE(), resolver);
        vm.stopPrank();
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
