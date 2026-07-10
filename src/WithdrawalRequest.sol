// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {
    AccessControlUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC721Upgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBag} from "src/interface/IBag.sol";
import {IBeaconProxyFactory} from "src/interface/IBeaconProxyFactory.sol";
import {IAuth} from "src/interface/IAuth.sol";

interface IWithdrawAssetVault is IERC20 {
    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
    function processAccounting() external;
}

/// @title WithdrawalRequest
/// @notice Custodies one yn-token type and tracks permissioned fulfilment of withdrawal requests.
contract WithdrawalRequest is Initializable, AccessControlUpgradeable, ERC721Upgradeable, PausableUpgradeable, IAuth {
    using SafeERC20 for IERC20;

    string public constant VERSION = "0.1.0";

    struct Request {
        address bag;
        uint256 amountLocked;
        address[] assetsRedeemed;
    }

    /// @custom:storage-location erc7201:yieldnest.storage.withdrawal_request_manager
    struct RequestStorage {
        IWithdrawAssetVault token;
        IBeaconProxyFactory beaconFactory;
        uint256 minWithdrawalAmount;
        uint256 nextRequestId;
        mapping(uint256 id => Request request) requests;
    }

    error ZeroAddress();
    error ZeroAmount();
    error AmountBelowMinimum(uint256 amount, uint256 minWithdrawalAmount);
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
    event MinWithdrawalAmountUpdated(uint256 oldMinWithdrawalAmount, uint256 newMinWithdrawalAmount);

    bytes32 public constant FULFILLER_ROLE = keccak256("FULFILLER_ROLE");
    bytes32 public constant CONFIGURATION_MANAGER_ROLE = keccak256("CONFIGURATION_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // keccak256(abi.encode(uint256(keccak256("yieldnest.storage.withdrawal_request_manager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RequestStorageLocation =
        0x15a0bae20a3f0267f2acf0f91b407bda6fc5d0eeb31acffcadb37a1c9e929100;

    function _getRequestStorage() private pure returns (RequestStorage storage $) {
        assembly {
            $.slot := RequestStorageLocation
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
        uint256 minWithdrawalAmount_
    ) external initializer {
        if (
            token_ == address(0) || defaultAdmin == address(0) || fulfiller == address(0)
                || configurationManager == address(0) || pauser == address(0) || beaconFactory_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __ERC721_init("MAX Vault Withdrawal Request", "ynWREQ");
        __Pausable_init();

        RequestStorage storage $ = _getRequestStorage();
        $.token = IWithdrawAssetVault(token_);
        $.beaconFactory = IBeaconProxyFactory(beaconFactory_);
        $.minWithdrawalAmount = minWithdrawalAmount_;

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(FULFILLER_ROLE, fulfiller);
        _grantRole(CONFIGURATION_MANAGER_ROLE, configurationManager);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // --- Configuration ---

    function setMinWithdrawalAmount(uint256 minWithdrawalAmount_) external onlyRole(CONFIGURATION_MANAGER_ROLE) {
        RequestStorage storage $ = _getRequestStorage();
        uint256 oldMinWithdrawalAmount = $.minWithdrawalAmount;
        $.minWithdrawalAmount = minWithdrawalAmount_;

        emit MinWithdrawalAmountUpdated(oldMinWithdrawalAmount, minWithdrawalAmount_);
    }

    // --- Requests ---

    /// @notice Locks yn-tokens in this contract and creates a withdrawal request.
    /// @param amount Amount of configured yn-token shares to lock.
    /// @param receiver Receiver of the request NFT that controls claims.
    /// @return id Generated request id.
    function requestWithdrawal(uint256 amount, address receiver) external whenNotPaused returns (uint256 id) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        RequestStorage storage $ = _getRequestStorage();
        if (amount < $.minWithdrawalAmount) revert AmountBelowMinimum(amount, $.minWithdrawalAmount);

        IERC20(address($.token)).safeTransferFrom(msg.sender, address(this), amount);

        id = $.nextRequestId++;
        address bag = $.beaconFactory.create(abi.encodeCall(IBag.initialize, (address(this), id)));
        $.requests[id].bag = bag;
        $.requests[id].amountLocked = amount;
        _mint(receiver, id);

        emit WithdrawalRequested(id, receiver, address($.token), bag, amount);
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

    function _fulfillWithdrawalRequest(uint256 id, address asset, uint256 assets)
        internal
        returns (uint256 amountBurned, uint256 assetsWithdrawn)
    {
        if (asset == address(0)) revert ZeroAddress();

        RequestStorage storage $ = _getRequestStorage();
        Request storage request = $.requests[id];
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

        _recordAssetRedeemed(request, asset);

        request.amountLocked -= amountBurned;

        $.token.processAccounting();

        emit WithdrawalRequestFulfilled(
            id, ownerOf(id), address($.token), asset, assetsWithdrawn, amountBurned, request.amountLocked
        );
    }

    // --- Views ---

    /// @notice Returns the configured yn-token handled by this withdrawal request contract.
    /// @return The configured yn-token.
    function token() public view returns (IWithdrawAssetVault) {
        return _getRequestStorage().token;
    }

    /// @notice Returns the beacon factory used to create request bags.
    /// @return The beacon factory contract.
    function beaconFactory() public view returns (IBeaconProxyFactory) {
        return _getRequestStorage().beaconFactory;
    }

    /// @notice Returns the minimum yn-token share amount required to open a request.
    /// @return The minimum amount to lock.
    function minWithdrawalAmount() public view returns (uint256) {
        return _getRequestStorage().minWithdrawalAmount;
    }

    /// @notice Returns the next withdrawal request id to be assigned.
    /// @return The next request id.
    function nextRequestId() public view returns (uint256) {
        return _getRequestStorage().nextRequestId;
    }

    /// @notice Returns a withdrawal request by id.
    /// @param id Request id to query.
    /// @return The stored withdrawal request.
    function requests(uint256 id) public view returns (Request memory) {
        Request memory request = _getRequestStorage().requests[id];
        if (!_requestExists(request)) revert RequestNotFound(id);

        return request;
    }

    /// @notice Returns whether a withdrawal request exists.
    /// @param id Request id to query.
    /// @return True if the request exists.
    function requestExists(uint256 id) public view returns (bool) {
        return _requestExists(_getRequestStorage().requests[id]);
    }

    /// @notice Returns whether `spender` owns or is approved to operate the request NFT.
    /// @param spender Account to check.
    /// @param id Request id to query.
    /// @return True if `spender` is the owner, approved address, or approved operator.
    function isAuthorized(address spender, uint256 id) external view override returns (bool) {
        address owner = ownerOf(id);
        return _isAuthorized(owner, spender, id);
    }

    function _requestExists(Request memory request) internal pure returns (bool) {
        return request.bag != address(0);
    }

    function _recordAssetRedeemed(Request storage request, address asset) internal {
        for (uint256 i = 0; i < request.assetsRedeemed.length; ++i) {
            if (request.assetsRedeemed[i] == asset) return;
        }

        request.assetsRedeemed.push(asset);
    }

    function ownerOf(uint256 id) public view override(ERC721Upgradeable, IAuth) returns (address) {
        return super.ownerOf(id);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // --- Pause ---

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
