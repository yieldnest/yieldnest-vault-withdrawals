// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IBag} from "src/interface/IBag.sol";
import {VaultMath} from "src/library/VaultMath.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {
    SetupWithdrawalRequest,
    TestRateProvider,
    WithdrawalAssetMock
} from "test/local/unit/helpers/SetupWithdrawalRequest.sol";

contract WithdrawalRequestAccountingHandler is Test {
    using Math for uint256;

    WithdrawalRequest internal immutable manager;
    IERC20 internal immutable token;
    IVault internal immutable vault;
    WithdrawalAssetMock internal immutable assetToken;
    WithdrawalAssetMock internal immutable secondAssetToken;
    TestRateProvider internal immutable rateProvider;
    address internal immutable asset;
    address internal immutable secondAsset;
    uint256 internal immutable minWithdrawalAmount;

    uint256 public depositedEver;
    uint256 public burnedEver;
    uint256 public maxResolveValueDrift;
    uint256 public maxResolveValueDriftExcess;
    mapping(uint256 id => uint256 amount) public initialLocked;
    mapping(uint256 id => uint256 amount) public burnedById;
    mapping(uint256 id => uint256 amount) public resolvedAssetsById;
    mapping(uint256 id => uint256 value) public resolvedValueById;
    mapping(uint256 id => uint256 amount) public lastObservedAmountLocked;

    constructor(
        WithdrawalRequest manager_,
        IERC20 token_,
        IVault vault_,
        WithdrawalAssetMock asset_,
        WithdrawalAssetMock secondAsset_,
        TestRateProvider rateProvider_,
        uint256 minWithdrawalAmount_
    ) {
        manager = manager_;
        token = token_;
        vault = vault_;
        assetToken = asset_;
        secondAssetToken = secondAsset_;
        rateProvider = rateProvider_;
        asset = address(asset_);
        secondAsset = address(secondAsset_);
        minWithdrawalAmount = minWithdrawalAmount_;
        token.approve(address(manager_), type(uint256).max);
    }

    function requestWithdrawal(uint256 amount) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance < minWithdrawalAmount) return;

        amount = bound(amount, minWithdrawalAmount, balance);
        uint256 id = manager.requestWithdrawal(amount, address(this));

        depositedEver += amount;
        initialLocked[id] = amount;
        lastObservedAmountLocked[id] = amount;
    }

    function resolveWithdrawalRequest(uint256 seed, uint256 assets) external {
        _resolveWithdrawalRequest(seed, asset, assets);
    }

    function resolveSecondAssetWithdrawalRequest(uint256 seed, uint256 assets) external {
        _resolveWithdrawalRequest(seed, secondAsset, assets);
    }

    function claimResolvedAsset(uint256 seed, uint256 amount) external {
        uint256 nextRequestId = manager.nextRequestId();
        if (nextRequestId == 0) return;

        uint256 id = seed % nextRequestId;
        if (!manager.requestExists(id)) return;

        WithdrawalRequest.Request memory request = manager.requests(id);
        address asset_ = seed % 2 == 0 ? asset : secondAsset;
        uint256 balance = IERC20(asset_).balanceOf(request.bag);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        address[] memory assets = new address[](1);
        assets[0] = asset_;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(manager.ownerOf(id));
        IBag(request.bag).claim(assets, payable(address(this)), amounts);
    }

    function transferRequest(uint256 seed) external {
        uint256 nextRequestId = manager.nextRequestId();
        if (nextRequestId == 0) return;

        uint256 id = seed % nextRequestId;
        if (!manager.requestExists(id)) return;

        address owner = manager.ownerOf(id);
        address newOwner = owner == address(this) ? address(0xBEEF) : address(this);

        vm.prank(owner);
        manager.transferFrom(owner, newOwner, id);
    }

    function burnResolvedAndClaimedRequest(uint256 seed) external {
        uint256 nextRequestId = manager.nextRequestId();
        if (nextRequestId == 0) return;

        uint256 id = seed % nextRequestId;
        if (!manager.requestExists(id)) return;

        WithdrawalRequest.Request memory request = manager.requests(id);
        if (request.amountLocked != 0) return;

        for (uint256 i = 0; i < request.assetsRedeemed.length; ++i) {
            if (IERC20(request.assetsRedeemed[i]).balanceOf(request.bag) != 0) return;
        }

        vm.prank(manager.ownerOf(id));
        manager.burn(id);
        lastObservedAmountLocked[id] = 0;
    }

    function accrueRewards(uint256 rewardAmount, uint256 defaultAssetRate, uint256 secondAssetRate) external {
        rewardAmount = bound(rewardAmount, 0, 10 ether);
        defaultAssetRate = bound(defaultAssetRate, 0.5 ether, 2 ether);
        secondAssetRate = bound(secondAssetRate, 0.5 ether, 2 ether);

        if (rewardAmount != 0) {
            if (rewardAmount % 2 == 0) {
                assetToken.mint(address(vault), rewardAmount);
            } else {
                secondAssetToken.mint(address(vault), rewardAmount);
            }
        }
        rateProvider.setRate(asset, defaultAssetRate);
        rateProvider.setRate(secondAsset, secondAssetRate);
        vault.processAccounting();
    }

    function _resolveWithdrawalRequest(uint256 seed, address asset_, uint256 assets) internal {
        uint256 nextRequestId = manager.nextRequestId();
        if (nextRequestId == 0) return;

        uint256 id = seed % nextRequestId;
        if (!manager.requestExists(id)) return;

        WithdrawalRequest.Request memory request = manager.requests(id);
        if (request.amountLocked == 0) return;

        uint256 maxAssets = _maxResolutionAssets(asset_, request.amountLocked);
        if (maxAssets == 0) return;

        assets = bound(assets, 1, maxAssets);
        uint256 valueBefore = _requestValue(id, request.amountLocked);

        uint256 amountBurned = manager.resolveWithdrawalRequest(id, asset_, assets);
        WithdrawalRequest.Request memory updatedRequest = manager.requests(id);

        burnedEver += amountBurned;
        burnedById[id] += amountBurned;
        resolvedAssetsById[id] += assets;
        resolvedValueById[id] += _assetValue(asset_, assets);
        lastObservedAmountLocked[id] = updatedRequest.amountLocked;

        uint256 valueAfter = _requestValue(id, updatedRequest.amountLocked);
        uint256 drift = valueBefore > valueAfter ? valueBefore - valueAfter : valueAfter - valueBefore;
        if (drift > maxResolveValueDrift) maxResolveValueDrift = drift;

        uint256 tolerance = _oneShareWeiValueCeil() + 4;
        if (drift > tolerance) {
            uint256 excess = drift - tolerance;
            if (excess > maxResolveValueDriftExcess) maxResolveValueDriftExcess = excess;
        }
    }

    function _sharesValue(uint256 shares) internal view returns (uint256) {
        uint256 defaultAssetAmount = manager.withdrawer().convertToAssets(shares);
        return _assetValue(vault.asset(), defaultAssetAmount);
    }

    function _assetValue(address asset_, uint256 amount) internal view returns (uint256) {
        IVault.AssetParams memory assetParams = vault.getAsset(asset_);
        uint256 rate = IProvider(vault.provider()).getRate(asset_);
        return amount.mulDiv(rate, 10 ** assetParams.decimals, Math.Rounding.Floor);
    }

    function _requestValue(uint256 id, uint256 amountLocked) internal view returns (uint256) {
        return _sharesValue(amountLocked) + resolvedValueById[id];
    }

    function _maxResolutionAssets(address asset_, uint256 amountLocked) internal view returns (uint256) {
        uint256 shareLimitedAssets = VaultMath.convertToAssets(vault, asset_, amountLocked);
        uint256 balanceLimitedAssets = IERC20(asset_).balanceOf(address(vault));
        return Math.min(shareLimitedAssets, balanceLimitedAssets);
    }

    function _oneShareWeiValueCeil() internal view returns (uint256) {
        return vault.totalBaseAssets().mulDiv(1, token.totalSupply(), Math.Rounding.Ceil);
    }
}

contract WithdrawalRequestInvariantTest is StdInvariant, SetupWithdrawalRequest {
    WithdrawalRequestAccountingHandler internal handler;

    function setUp() public {
        setUpWithdrawalRequest();

        handler = new WithdrawalRequestAccountingHandler(
            manager,
            IERC20(address(ynToken)),
            IVault(address(ynToken)),
            asset,
            secondAsset,
            rateProvider,
            minWithdrawalAmount
        );
        _mintVaultShares(address(handler), 1_000 ether);

        vm.startPrank(admin);
        manager.grantRole(manager.RESOLVER_ROLE(), address(handler));
        manager.revokeRole(manager.RESOLVER_ROLE(), resolver);
        vm.stopPrank();

        targetContract(address(handler));
    }

    function invariant_sumOfAmountLockedEqualsManagerTokenBalance() public view {
        assertEq(_sumLiveAmountLocked(), ynToken.balanceOf(address(manager)));
    }

    function invariant_timeIntegratedShareConservation() public view {
        assertEq(handler.burnedEver() + _sumLiveAmountLocked(), handler.depositedEver());
    }

    function invariant_managerIsPureConduit() public view {
        assertEq(asset.balanceOf(address(manager)), 0);
        assertEq(secondAsset.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
    }

    function invariant_amountLockedMonotonicAndBelowInitial() public view {
        uint256 nextRequestId = manager.nextRequestId();

        for (uint256 id = 0; id < nextRequestId; ++id) {
            if (handler.initialLocked(id) == 0) continue;

            uint256 amountLocked = manager.requestExists(id) ? manager.requests(id).amountLocked : 0;
            assertLe(amountLocked, handler.initialLocked(id));
            assertLe(amountLocked, handler.lastObservedAmountLocked(id));
        }
    }

    function invariant_perRequestBurnConservation() public view {
        uint256 nextRequestId = manager.nextRequestId();

        for (uint256 id = 0; id < nextRequestId; ++id) {
            if (handler.initialLocked(id) == 0) continue;

            uint256 amountLocked = manager.requestExists(id) ? manager.requests(id).amountLocked : 0;
            assertEq(handler.burnedById(id), handler.initialLocked(id) - amountLocked);
        }
    }

    function invariant_resolveValueDriftIsBounded() public view {
        assertEq(handler.maxResolveValueDriftExcess(), 0);
    }

    function _sumLiveAmountLocked() internal view returns (uint256 amountLockedSum) {
        uint256 nextRequestId = manager.nextRequestId();

        for (uint256 id = 0; id < nextRequestId; ++id) {
            if (!manager.requestExists(id)) continue;
            amountLockedSum += manager.requests(id).amountLocked;
        }
    }
}
