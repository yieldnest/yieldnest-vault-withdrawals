// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {
    AccessControlUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IBag} from "src/interface/IBag.sol";
import {IBeaconProxyFactory} from "src/interface/IBeaconProxyFactory.sol";

interface IWithdrawAssetVault is IERC20 {
    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
    function totalBaseAssets() external view returns (uint256);
    function provider() external view returns (address);
    function getAsset(address asset_) external view returns (IVault.AssetParams memory);
    function processAccounting() external;
}

/// @title WithdrawalRequestManager
/// @notice Custodies one yn-token type and tracks permissioned fulfilment of withdrawal requests.
contract WithdrawalRequestManager is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    string public constant VERSION = "0.1.0";

    struct WithdrawalRequest {
        address owner;
        address bag;
        uint256 amountLocked;
    }

    /// @custom:storage-location erc7201:yieldnest.storage.withdrawal_request_manager
    struct WithdrawalRequestManagerStorage {
        IWithdrawAssetVault token;
        IBeaconProxyFactory beaconFactory;
        uint256 minimumAmountToLock;
        uint256 nextRequestId;
        mapping(uint256 id => WithdrawalRequest request) requests;
    }

    error ZeroAddress();
    error ZeroAmount();
    error AmountBelowMinimum(uint256 amount, uint256 minimumAmountToLock);
    error RequestNotFound(uint256 id);
    error InsufficientLockedAmount(uint256 id, uint256 amountLocked, uint256 amountBurned);
    error InvalidTokenBalanceChange(uint256 balanceBefore, uint256 balanceAfter);
    error InvalidAssetBalanceChange(uint256 balanceBefore, uint256 balanceAfter);
    error UnexpectedAssetsWithdrawn(uint256 expectedAssets, uint256 actualAssets);

    event WithdrawalRequested(
        uint256 indexed id, address indexed owner, address indexed token, address bag, uint256 amountLocked
    );
    event WithdrawalRequestFulfilled(
        uint256 indexed id,
        address indexed owner,
        address indexed token,
        address asset,
        uint256 assetsWithdrawn,
        uint256 amountBurned,
        uint256 amountLocked
    );
    event MinimumAmountToLockUpdated(uint256 oldMinimumAmountToLock, uint256 newMinimumAmountToLock);

    bytes32 public constant FULFILLER_ROLE = keccak256("FULFILLER_ROLE");
    bytes32 public constant CONFIGURATION_MANAGER_ROLE = keccak256("CONFIGURATION_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // keccak256(abi.encode(uint256(keccak256("yieldnest.storage.withdrawal_request_manager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WithdrawalRequestManagerStorageLocation =
        0x15a0bae20a3f0267f2acf0f91b407bda6fc5d0eeb31acffcadb37a1c9e929100;

    function _getWithdrawalRequestManagerStorage() private pure returns (WithdrawalRequestManagerStorage storage $) {
        assembly {
            $.slot := WithdrawalRequestManagerStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address token_,
        address defaultAdmin,
        address fulfiller,
        address configurationManager,
        address pauser,
        address beaconFactory_,
        uint256 minimumAmountToLock_
    ) external initializer {
        if (
            token_ == address(0) || defaultAdmin == address(0) || fulfiller == address(0)
                || configurationManager == address(0) || pauser == address(0) || beaconFactory_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        WithdrawalRequestManagerStorage storage $ = _getWithdrawalRequestManagerStorage();
        $.token = IWithdrawAssetVault(token_);
        $.beaconFactory = IBeaconProxyFactory(beaconFactory_);
        $.minimumAmountToLock = minimumAmountToLock_;
        $.nextRequestId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(FULFILLER_ROLE, fulfiller);
        _grantRole(CONFIGURATION_MANAGER_ROLE, configurationManager);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // --- Configuration ---

    function setMinimumAmountToLock(uint256 minimumAmountToLock_) external onlyRole(CONFIGURATION_MANAGER_ROLE) {
        WithdrawalRequestManagerStorage storage $ = _getWithdrawalRequestManagerStorage();
        uint256 oldMinimumAmountToLock = $.minimumAmountToLock;
        $.minimumAmountToLock = minimumAmountToLock_;

        emit MinimumAmountToLockUpdated(oldMinimumAmountToLock, minimumAmountToLock_);
    }

    // --- Requests ---

    /// @notice Locks yn-tokens in this contract and creates a withdrawal request.
    /// @param amount Amount of configured yn-token shares to lock.
    /// @param receiver Receiver of the Bag NFT that controls claims.
    /// @return id Generated request id.
    function requestWithdrawal(uint256 amount, address receiver) external whenNotPaused returns (uint256 id) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        WithdrawalRequestManagerStorage storage $ = _getWithdrawalRequestManagerStorage();
        if (amount < $.minimumAmountToLock) revert AmountBelowMinimum(amount, $.minimumAmountToLock);

        IERC20(address($.token)).safeTransferFrom(msg.sender, address(this), amount);

        id = $.nextRequestId++;
        address bag = $.beaconFactory.create(abi.encodeCall(IBag.initialize, (receiver, id)));
        $.requests[id] = WithdrawalRequest({owner: bag, bag: bag, amountLocked: amount});

        emit WithdrawalRequested(id, bag, address($.token), bag, amount);
    }

    // --- Fulfillment ---

    /// @notice Fulfils part or all of a request by withdrawing an asset from the configured yn-token.
    /// @param id Request id to fulfil.
    /// @param asset Asset to withdraw from the yn-token.
    /// @param assets Amount of `asset` to withdraw to the request bag.
    /// @return amountBurned Amount of locked yn-token shares burned by the withdrawal.
    function fulfillWithdrawalRequest(uint256 id, address asset, uint256 assets)
        external
        onlyRole(FULFILLER_ROLE)
        returns (uint256 amountBurned)
    {
        (amountBurned,) = _fulfillWithdrawalRequest(id, asset, assets);
    }

    /// @notice Fulfils as much of a request as possible for a given asset using the currently locked shares.
    /// @dev Requests store only shares, and the fulfiller chooses the withdrawal asset at fulfilment.
    /// @param id Request id to fulfil.
    /// @param asset Asset to withdraw from the yn-token.
    /// @return amountBurned Amount of locked yn-token shares burned by the withdrawal.
    /// @return assetsWithdrawn Amount of `asset` transferred to the request bag.
    function fulfillWithdrawalRequestMax(uint256 id, address asset)
        external
        onlyRole(FULFILLER_ROLE)
        returns (uint256 amountBurned, uint256 assetsWithdrawn)
    {
        if (asset == address(0)) revert ZeroAddress();

        WithdrawalRequest memory request = requests(id);

        // Asset pricing depends on provider/oracle rates, which may be stale or incorrect. If an asset is
        // underpriced, requesters can receive more real value than the burned shares represent, diluting
        // remaining depositors. Inventory limits and operator diligence mitigate, but do not remove, this risk.
        // Assumes asset withdrawals from the configured yn-token are feeless.
        // Rounds down so max fulfilment does not intentionally request assets requiring more shares than are locked.
        uint256 assets = convertToAssets(asset, request.amountLocked);
        (amountBurned, assetsWithdrawn) = _fulfillWithdrawalRequest(id, asset, assets);
    }

    function _fulfillWithdrawalRequest(uint256 id, address asset, uint256 assets)
        internal
        returns (uint256 amountBurned, uint256 assetsWithdrawn)
    {
        if (asset == address(0)) revert ZeroAddress();

        WithdrawalRequestManagerStorage storage $ = _getWithdrawalRequestManagerStorage();
        WithdrawalRequest storage request = $.requests[id];
        if (!_requestExists(request)) revert RequestNotFound(id);

        if (assets == 0) revert ZeroAmount();

        address bag = request.bag;
        uint256 tokenBalanceBefore = $.token.balanceOf(address(this));
        uint256 assetBalanceBefore = IERC20(asset).balanceOf(bag);

        $.token.withdrawAsset(asset, assets, bag, address(this));

        uint256 tokenBalanceAfter = $.token.balanceOf(address(this));
        if (tokenBalanceAfter > tokenBalanceBefore) {
            revert InvalidTokenBalanceChange(tokenBalanceBefore, tokenBalanceAfter);
        }

        uint256 assetBalanceAfter = IERC20(asset).balanceOf(bag);
        if (assetBalanceAfter < assetBalanceBefore) {
            revert InvalidAssetBalanceChange(assetBalanceBefore, assetBalanceAfter);
        }

        amountBurned = tokenBalanceBefore - tokenBalanceAfter;
        if (amountBurned > request.amountLocked) {
            revert InsufficientLockedAmount(id, request.amountLocked, amountBurned);
        }

        assetsWithdrawn = assetBalanceAfter - assetBalanceBefore;
        if (assetsWithdrawn != assets) revert UnexpectedAssetsWithdrawn(assets, assetsWithdrawn);

        request.amountLocked -= amountBurned;

        $.token.processAccounting();

        emit WithdrawalRequestFulfilled(
            id, request.owner, address($.token), asset, assetsWithdrawn, amountBurned, request.amountLocked
        );
    }

    // --- Views ---

    /// @notice Returns the configured yn-token handled by this manager.
    /// @return The configured yn-token.
    function token() public view returns (IWithdrawAssetVault) {
        return _getWithdrawalRequestManagerStorage().token;
    }

    /// @notice Returns the beacon factory used to create request bags.
    /// @return The beacon factory contract.
    function beaconFactory() public view returns (IBeaconProxyFactory) {
        return _getWithdrawalRequestManagerStorage().beaconFactory;
    }

    /// @notice Returns the minimum yn-token share amount required to open a request.
    /// @return The minimum amount to lock.
    function minimumAmountToLock() public view returns (uint256) {
        return _getWithdrawalRequestManagerStorage().minimumAmountToLock;
    }

    /// @notice Returns the next withdrawal request id to be assigned.
    /// @return The next request id.
    function nextRequestId() public view returns (uint256) {
        return _getWithdrawalRequestManagerStorage().nextRequestId;
    }

    /// @notice Returns a withdrawal request by id.
    /// @param id Request id to query.
    /// @return The stored withdrawal request.
    function requests(uint256 id) public view returns (WithdrawalRequest memory) {
        WithdrawalRequest memory request = _getWithdrawalRequestManagerStorage().requests[id];
        if (!_requestExists(request)) revert RequestNotFound(id);

        return request;
    }

    /// @notice Returns whether a withdrawal request exists.
    /// @param id Request id to query.
    /// @return True if the request exists.
    function requestExists(uint256 id) public view returns (bool) {
        return _requestExists(_getWithdrawalRequestManagerStorage().requests[id]);
    }

    function _requestExists(WithdrawalRequest memory request) internal pure returns (bool) {
        return request.owner != address(0);
    }

    /// @notice Converts yn-token shares into the maximum amount of a given asset withdrawable from the configured token.
    /// @param asset Asset to convert into.
    /// @param shares Amount of yn-token shares to convert.
    /// @return assets Amount of `asset` represented by `shares`.
    function convertToAssets(address asset, uint256 shares) public view returns (uint256 assets) {
        IWithdrawAssetVault token_ = _getWithdrawalRequestManagerStorage().token;
        uint256 totalSupply = token_.totalSupply();
        uint256 totalBaseAssets = token_.totalBaseAssets();
        uint256 baseAssets = shares.mulDiv(totalBaseAssets + 1, totalSupply + 1, Math.Rounding.Floor);

        IVault.AssetParams memory assetParams = token_.getAsset(asset);
        uint256 rate = IProvider(token_.provider()).getRate(asset);
        assets = baseAssets.mulDiv(10 ** assetParams.decimals, rate, Math.Rounding.Floor);
    }

    // --- Pause ---

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
