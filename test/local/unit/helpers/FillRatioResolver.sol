// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {IVaultMathVault, VaultMath} from "src/library/VaultMath.sol";

/// @notice Test-only resolver that lets request NFT owners resolve up to a permissioned global fill ratio.
/// @dev The fill ratio is share-based; the resolver converts the newly available share budget to assets
/// before calling the asset-denominated WithdrawalRequest resolution API.
contract FillRatioResolver {
    uint256 public constant MAX_FILL_RATIO_BPS = 10_000;

    WithdrawalRequest public immutable manager;
    address public immutable redemptionAsset;
    address public immutable fillRatioManager;

    uint256 public fillRatioBps;
    mapping(uint256 id => uint256 amount) public initialAmountLocked;

    error FillRatioTooHigh(uint256 fillRatioBps);
    error FillRatioCannotDecrease(uint256 currentFillRatioBps, uint256 newFillRatioBps);
    error NotFillRatioManager(address caller);
    error NotRequestOwner(address caller, address owner);
    error NothingToResolve(uint256 id);

    event FillRatioUpdated(uint256 oldFillRatioBps, uint256 newFillRatioBps);

    constructor(WithdrawalRequest manager_, address redemptionAsset_, address fillRatioManager_) {
        manager = manager_;
        redemptionAsset = redemptionAsset_;
        fillRatioManager = fillRatioManager_;
    }

    function setFillRatioBps(uint256 newFillRatioBps) external {
        if (msg.sender != fillRatioManager) revert NotFillRatioManager(msg.sender);
        if (newFillRatioBps > MAX_FILL_RATIO_BPS) revert FillRatioTooHigh(newFillRatioBps);

        uint256 oldFillRatioBps = fillRatioBps;
        if (newFillRatioBps < oldFillRatioBps) revert FillRatioCannotDecrease(oldFillRatioBps, newFillRatioBps);

        fillRatioBps = newFillRatioBps;
        emit FillRatioUpdated(oldFillRatioBps, newFillRatioBps);
    }

    function resolveAvailable(uint256 id) external returns (uint256 amountBurned) {
        address owner = manager.ownerOf(id);
        if (msg.sender != owner) revert NotRequestOwner(msg.sender, owner);

        WithdrawalRequest.Request memory request = manager.requests(id);
        uint256 initialAmount = initialAmountLocked[id];
        if (initialAmount == 0) {
            initialAmount = request.amountLocked;
            initialAmountLocked[id] = initialAmount;
        }

        uint256 resolvedShares = initialAmount - request.amountLocked;
        uint256 targetResolvedShares = initialAmount * fillRatioBps / MAX_FILL_RATIO_BPS;
        if (targetResolvedShares <= resolvedShares) revert NothingToResolve(id);

        uint256 sharesToResolve = targetResolvedShares - resolvedShares;
        uint256 assetsToResolve =
            VaultMath.convertToAssets(IVaultMathVault(address(manager.token())), redemptionAsset, sharesToResolve);
        if (assetsToResolve == 0) revert NothingToResolve(id);

        amountBurned = manager.resolveWithdrawalRequest(id, redemptionAsset, assetsToResolve);
    }
}
