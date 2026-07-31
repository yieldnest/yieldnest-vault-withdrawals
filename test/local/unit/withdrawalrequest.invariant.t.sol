// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {SetupWithdrawalRequest} from "test/local/unit/helpers/SetupWithdrawalRequest.sol";

contract WithdrawalRequestAccountingHandler is Test {
    using Math for uint256;

    WithdrawalRequest internal immutable manager;
    IERC20 internal immutable token;
    IVault internal immutable vault;
    address internal immutable asset;
    uint256 internal immutable minWithdrawalAmount;

    uint256 public depositedEver;
    uint256 public burnedEver;
    uint256 public liveAmountLocked;
    mapping(uint256 id => uint256 amount) public initialLocked;
    mapping(uint256 id => uint256 amount) public burnedById;
    mapping(uint256 id => uint256 value) public initialValueById;
    mapping(uint256 id => uint256 value) public lockedValueById;
    mapping(uint256 id => uint256 amount) public resolvedAssetsById;
    mapping(uint256 id => uint256 value) public resolvedValueById;
    mapping(uint256 id => uint256 amount) public lastObservedAmountLocked;

    constructor(
        WithdrawalRequest manager_,
        IERC20 token_,
        IVault vault_,
        address asset_,
        uint256 minWithdrawalAmount_
    ) {
        manager = manager_;
        token = token_;
        vault = vault_;
        asset = asset_;
        minWithdrawalAmount = minWithdrawalAmount_;
        token.approve(address(manager_), type(uint256).max);
    }

    function requestWithdrawal(uint256 amount) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance < minWithdrawalAmount) return;

        amount = bound(amount, minWithdrawalAmount, balance);
        uint256 id = manager.requestWithdrawal(amount, address(this));

        depositedEver += amount;
        liveAmountLocked += amount;
        initialLocked[id] = amount;
        lastObservedAmountLocked[id] = amount;
        initialValueById[id] = _sharesValue(amount);
        lockedValueById[id] = initialValueById[id];
    }

    function resolveWithdrawalRequest(uint256 seed, uint256 assets) external {
        uint256 nextRequestId = manager.nextRequestId();
        if (nextRequestId == 0) return;

        uint256 id = seed % nextRequestId;
        if (!manager.requestExists(id)) return;

        WithdrawalRequest.Request memory request = manager.requests(id);
        if (request.amountLocked == 0) return;

        assets = bound(assets, 1, request.amountLocked);
        uint256 amountBurned = manager.resolveWithdrawalRequest(id, asset, assets);
        WithdrawalRequest.Request memory updatedRequest = manager.requests(id);

        burnedEver += amountBurned;
        liveAmountLocked -= amountBurned;
        burnedById[id] += amountBurned;
        resolvedAssetsById[id] += assets;
        resolvedValueById[id] += _assetValue(asset, assets);
        lockedValueById[id] = _sharesValue(updatedRequest.amountLocked);
        lastObservedAmountLocked[id] = updatedRequest.amountLocked;
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
}

contract WithdrawalRequestInvariantTest is StdInvariant, SetupWithdrawalRequest {
    uint256 internal constant VALUE_TOLERANCE_PER_REQUEST = 2;

    WithdrawalRequestAccountingHandler internal handler;

    function setUp() public {
        setUpWithdrawalRequest();

        handler = new WithdrawalRequestAccountingHandler(
            manager, IERC20(address(ynToken)), IVault(address(ynToken)), address(asset), minWithdrawalAmount
        );
        _mintVaultShares(address(handler), 1_000 ether);

        vm.startPrank(admin);
        manager.grantRole(manager.RESOLVER_ROLE(), address(handler));
        manager.revokeRole(manager.RESOLVER_ROLE(), resolver);
        vm.stopPrank();

        targetContract(address(handler));
    }

    function invariant_sumOfAmountLockedEqualsManagerTokenBalance() public view {
        assertEq(handler.liveAmountLocked(), ynToken.balanceOf(address(manager)));
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
            if (!manager.requestExists(id)) continue;

            uint256 amountLocked = manager.requests(id).amountLocked;
            assertLe(amountLocked, handler.initialLocked(id));
            assertLe(amountLocked, handler.lastObservedAmountLocked(id));
        }
    }

    function invariant_perRequestBurnConservation() public view {
        uint256 nextRequestId = manager.nextRequestId();

        for (uint256 id = 0; id < nextRequestId; ++id) {
            if (!manager.requestExists(id)) continue;

            uint256 amountLocked = manager.requests(id).amountLocked;
            assertEq(handler.burnedById(id), handler.initialLocked(id) - amountLocked);
        }
    }

    function invariant_requestValueIsApproximatelyConserved() public view {
        uint256 nextRequestId = manager.nextRequestId();

        for (uint256 id = 0; id < nextRequestId; ++id) {
            if (!manager.requestExists(id)) continue;

            uint256 initialValue = handler.initialValueById(id);
            uint256 currentValue = handler.lockedValueById(id) + handler.resolvedValueById(id);

            assertApproxEqAbs(currentValue, initialValue, VALUE_TOLERANCE_PER_REQUEST);
        }
    }

    function _sumLiveAmountLocked() internal view returns (uint256 amountLockedSum) {
        uint256 nextRequestId = manager.nextRequestId();

        for (uint256 id = 0; id < nextRequestId; ++id) {
            if (!manager.requestExists(id)) continue;
            amountLockedSum += manager.requests(id).amountLocked;
        }
    }
}
