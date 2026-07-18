// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {
    AccessControlUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {
    ERC721EnumerableUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ERC721Upgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBag} from "src/interface/IBag.sol";
import {IAuth} from "src/interface/IAuth.sol";
import {IResolver} from "src/interface/IResolver.sol";
import {IFactory} from "src/interface/IFactory.sol";
import {IRequestPolicy} from "src/interface/IRequestPolicy.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";

interface IWithdrawAssetVault is IERC20Metadata {
    /// @notice Withdraws a vault asset to a receiver and consumes shares from owner.
    /// @param asset_ Asset to withdraw.
    /// @param assets Amount of `asset_` to withdraw.
    /// @param receiver Receiver of the withdrawn asset.
    /// @param owner Owner whose shares are consumed.
    /// @return shares Amount of shares consumed.
    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Converts shares to the vault default asset amount.
    /// @param shares Amount of shares to convert.
    /// @return assets Amount of default asset represented by `shares`.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/// @title WithdrawalRequest
/// @notice Custodies one yn-token type and tracks permissioned resolution of withdrawal requests.
contract WithdrawalRequest is
    Initializable,
    AccessControlUpgradeable,
    ERC721EnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IAuth,
    IResolver
{
    using SafeERC20 for IERC20;

    string public constant VERSION = "0.1.0";

    struct Request {
        address bag;
        uint256 amountLocked;
        address[] assetsRedeemed;
        uint256 rateAtRequest;
        bytes data;
    }

    /// @custom:storage-location erc7201:yieldnest.storage.withdrawal_request_manager
    struct RequestStorage {
        IWithdrawAssetVault token;
        IFactory bagFactory;
        IWithdrawer withdrawer;
        IRequestPolicy requestPolicy;
        uint256 nextRequestId;
        mapping(uint256 id => Request request) requests;
    }

    error ZeroAddress();
    error ZeroAmount();
    error RequestNotFound(uint256 id);
    error InsufficientLockedAmount(uint256 id, uint256 amountLocked, uint256 amountBurned);
    error InvalidTokenBalanceChange(uint256 balanceBefore, uint256 balanceAfter);
    error InvalidAssetBalanceChange(uint256 balanceBefore, uint256 balanceAfter);
    error UnexpectedAssetsWithdrawn(uint256 expectedAssets, uint256 actualAssets);
    error ArrayLengthMismatch(uint256 assetsLength, uint256 assetAmountsLength);
    error DataTooLong(uint256 length, uint256 maxLength);

    event WithdrawalRequested(
        uint256 indexed id, address indexed owner, address indexed token, address bag, uint256 amountLocked, bytes data
    );
    event WithdrawalRequestResolved(
        uint256 indexed id,
        address indexed owner,
        address indexed token,
        address asset,
        uint256 assetsWithdrawn,
        uint256 amountBurned,
        uint256 amountLocked
    );
    event RequestPolicyUpdated(address oldRequestPolicy, address newRequestPolicy);
    event WithdrawerUpdated(address oldWithdrawer, address newWithdrawer);

    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant CONFIGURATION_MANAGER_ROLE = keccak256("CONFIGURATION_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant MAX_DATA_LENGTH = 1024;

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

    /// @notice Initializes the withdrawal request contract and its roles.
    /// @param token_ yn-token shares locked and resolved by this contract.
    /// @param defaultAdmin Account granted the default admin role.
    /// @param resolver Account granted permission to resolve requests.
    /// @param configurationManager Account granted permission to update configurable modules.
    /// @param pauser Account granted permission to pause and unpause request creation.
    /// @param bagFactory_ Factory used to deploy request bags.
    /// @param withdrawer_ Adapter used to withdraw assets from the yn-token.
    /// @param requestPolicy_ Policy used to validate request creation.
    function initialize(
        address token_,
        address defaultAdmin,
        address resolver,
        address configurationManager,
        address pauser,
        address bagFactory_,
        address withdrawer_,
        address requestPolicy_
    ) external initializer {
        if (
            token_ == address(0) || defaultAdmin == address(0) || resolver == address(0)
                || configurationManager == address(0) || pauser == address(0) || bagFactory_ == address(0)
                || withdrawer_ == address(0) || requestPolicy_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __ERC721_init("MAX Vault Withdrawal Request", "ynWREQ");
        __ERC721Enumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _initializeStorage(token_, bagFactory_, withdrawer_, requestPolicy_);

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(RESOLVER_ROLE, resolver);
        _grantRole(CONFIGURATION_MANAGER_ROLE, configurationManager);
        _grantRole(PAUSER_ROLE, pauser);
    }

    function _initializeStorage(address token_, address bagFactory_, address withdrawer_, address requestPolicy_)
        internal
    {
        RequestStorage storage $ = _getRequestStorage();
        $.token = IWithdrawAssetVault(token_);
        $.bagFactory = IFactory(bagFactory_);
        $.withdrawer = IWithdrawer(withdrawer_);
        $.requestPolicy = IRequestPolicy(requestPolicy_);
    }

    // --- Requests ---

    /// @notice Locks yn-tokens in this contract and creates a withdrawal request.
    /// @param amount Amount of configured yn-token shares to lock.
    /// @param receiver Receiver of the request NFT that controls claims.
    /// @return id Generated request id.
    function requestWithdrawal(uint256 amount, address receiver) external whenNotPaused returns (uint256 id) {
        id = _requestWithdrawal(amount, receiver, "");
    }

    /// @notice Locks yn-tokens in this contract and creates a withdrawal request with bounded data.
    /// @param amount Amount of configured yn-token shares to lock.
    /// @param receiver Receiver of the request NFT that controls claims.
    /// @param data Arbitrary request metadata, capped at `MAX_DATA_LENGTH` bytes.
    /// @return id Generated request id.
    function requestWithdrawal(uint256 amount, address receiver, bytes calldata data)
        external
        whenNotPaused
        returns (uint256 id)
    {
        id = _requestWithdrawal(amount, receiver, data);
    }

    function _requestWithdrawal(uint256 amount, address receiver, bytes memory data) internal returns (uint256 id) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (data.length > MAX_DATA_LENGTH) revert DataTooLong(data.length, MAX_DATA_LENGTH);

        RequestStorage storage $ = _getRequestStorage();
        $.requestPolicy.validateRequest(msg.sender, receiver, amount);

        IERC20(address($.token)).safeTransferFrom(msg.sender, address(this), amount);
        uint256 rateAtRequest = $.token.convertToAssets(10 ** $.token.decimals());

        id = $.nextRequestId++;
        address bag = $.bagFactory.create(abi.encodeCall(IBag.initialize, (address(this), id)));
        $.requests[id].bag = bag;
        $.requests[id].amountLocked = amount;
        $.requests[id].rateAtRequest = rateAtRequest;
        $.requests[id].data = data;
        _mint(receiver, id);

        emit WithdrawalRequested(id, receiver, address($.token), bag, amount, data);
    }

    // --- Resolution ---

    /// @notice Resolves part or all of a request by withdrawing an asset from the configured yn-token.
    /// @param id Request id to resolve.
    /// @param asset Asset to withdraw from the yn-token.
    /// @param assets Amount of `asset` to withdraw to the request bag.
    /// @return amountBurned Amount of locked yn-token shares burned by the withdrawal.
    function resolveWithdrawalRequest(uint256 id, address asset, uint256 assets)
        external
        override
        onlyRole(RESOLVER_ROLE)
        nonReentrant
        returns (uint256 amountBurned)
    {
        (amountBurned,) = _resolveWithdrawalRequest(id, asset, assets);
    }

    /// @notice Resolves a request across multiple assets.
    /// @param id Request id to resolve.
    /// @param assets Assets to withdraw from the yn-token.
    /// @param assetAmounts Amounts of each asset to withdraw to the request bag.
    /// @return amountsBurned Amounts of locked yn-token shares burned by each withdrawal.
    function resolveWithdrawalRequest(uint256 id, address[] calldata assets, uint256[] calldata assetAmounts)
        external
        override
        onlyRole(RESOLVER_ROLE)
        nonReentrant
        returns (uint256[] memory amountsBurned)
    {
        if (assets.length != assetAmounts.length) {
            revert ArrayLengthMismatch(assets.length, assetAmounts.length);
        }

        amountsBurned = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            (amountsBurned[i],) = _resolveWithdrawalRequest(id, assets[i], assetAmounts[i]);
        }
    }

    function _resolveWithdrawalRequest(uint256 id, address asset, uint256 assets)
        internal
        returns (uint256 tokenAmountBurned, uint256 assetsWithdrawn)
    {
        if (asset == address(0)) revert ZeroAddress();

        RequestStorage storage $ = _getRequestStorage();
        Request storage request = $.requests[id];
        if (!_requestExists(request)) revert RequestNotFound(id);

        if (assets == 0) revert ZeroAmount();

        address bag = request.bag;
        uint256 tokenBalanceBefore = $.token.balanceOf(address(this));
        uint256 bagAssetBalanceBefore = IERC20(asset).balanceOf(bag);

        // withdrawAsset to bag and burn yn-tokens
        IERC20(address($.token)).forceApprove(address($.withdrawer), request.amountLocked);
        tokenAmountBurned = $.withdrawer.withdrawAsset(id, asset, assets, bag, address(this));
        IERC20(address($.token)).forceApprove(address($.withdrawer), 0);

        {
            uint256 tokenBalanceAfter = $.token.balanceOf(address(this));
            if (tokenBalanceBefore - tokenBalanceAfter != tokenAmountBurned) {
                revert InvalidTokenBalanceChange(tokenBalanceBefore, tokenBalanceAfter);
            }

            if (tokenAmountBurned > request.amountLocked) {
                revert InsufficientLockedAmount(id, request.amountLocked, tokenAmountBurned);
            }

            assetsWithdrawn = IERC20(asset).balanceOf(bag) - bagAssetBalanceBefore;
            if (assetsWithdrawn != assets) revert UnexpectedAssetsWithdrawn(assets, assetsWithdrawn);
        }

        _recordAssetRedeemed(request, asset);

        request.amountLocked -= tokenAmountBurned;

        emit WithdrawalRequestResolved(
            id, ownerOf(id), address($.token), asset, assetsWithdrawn, tokenAmountBurned, request.amountLocked
        );
    }

    function _recordAssetRedeemed(Request storage request, address asset) internal {
        for (uint256 i = 0; i < request.assetsRedeemed.length; ++i) {
            if (request.assetsRedeemed[i] == asset) return;
        }

        request.assetsRedeemed.push(asset);
    }

    // --- Configuration ---

    /// @notice Updates the withdrawer adapter and revokes allowance from the old adapter.
    /// @param withdrawer_ New withdrawer adapter address.
    function setWithdrawer(address withdrawer_) external onlyRole(CONFIGURATION_MANAGER_ROLE) {
        if (withdrawer_ == address(0)) revert ZeroAddress();

        RequestStorage storage $ = _getRequestStorage();
        address oldWithdrawer = address($.withdrawer);
        IERC20(address($.token)).forceApprove(oldWithdrawer, 0);
        $.withdrawer = IWithdrawer(withdrawer_);

        emit WithdrawerUpdated(oldWithdrawer, withdrawer_);
    }

    /// @notice Updates the request policy used to validate new withdrawal requests.
    /// @param requestPolicy_ New request policy address.
    function setRequestPolicy(address requestPolicy_) external onlyRole(CONFIGURATION_MANAGER_ROLE) {
        if (requestPolicy_ == address(0)) revert ZeroAddress();

        RequestStorage storage $ = _getRequestStorage();
        address oldRequestPolicy = address($.requestPolicy);
        $.requestPolicy = IRequestPolicy(requestPolicy_);

        emit RequestPolicyUpdated(oldRequestPolicy, requestPolicy_);
    }

    // --- Pause ---

    /// @notice Pauses new withdrawal request creation.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses new withdrawal request creation.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- Views ---

    /// @notice Returns the configured yn-token handled by this withdrawal request contract.
    /// @return The configured yn-token.
    function token() public view returns (IWithdrawAssetVault) {
        return _getRequestStorage().token;
    }

    /// @notice Returns the factory used to create request bags.
    /// @return The factory contract.
    function bagFactory() public view returns (IFactory) {
        return _getRequestStorage().bagFactory;
    }

    /// @notice Returns the adapter used to withdraw assets from the configured yn-token.
    /// @return The configured withdrawer.
    function withdrawer() public view returns (IWithdrawer) {
        return _getRequestStorage().withdrawer;
    }

    /// @notice Returns the next withdrawal request id to be assigned.
    /// @return The next request id.
    function nextRequestId() public view returns (uint256) {
        return _getRequestStorage().nextRequestId;
    }

    /// @notice Returns the policy that validates request creation.
    /// @return The configured request policy.
    function requestPolicy() public view returns (IRequestPolicy) {
        return _getRequestStorage().requestPolicy;
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

    function _requestExists(Request memory request) internal pure returns (bool) {
        return request.bag != address(0);
    }

    /// @notice Returns the owner of a request NFT.
    /// @param id Request id to query.
    /// @return Owner of the request NFT.
    function ownerOf(uint256 id) public view override(ERC721Upgradeable, IERC721, IAuth) returns (address) {
        return super.ownerOf(id);
    }

    /// @notice Returns whether this contract supports an interface id.
    /// @param interfaceId Interface id to query.
    /// @return True if the interface is supported.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
