// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";

/// @title BaseWithdrawer
/// @notice Authorized adapter that forwards withdrawals to the configured vault at its live redemption rate.
contract BaseWithdrawer is IWithdrawer {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:yieldnest.storage.base_withdrawer
    struct BaseWithdrawerStorage {
        IVault token;
        address withdrawalRequest;
    }

    error Unauthorized(address caller);
    error ZeroAddress();

    // keccak256(abi.encode(uint256(keccak256("yieldnest.storage.base_withdrawer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BaseWithdrawerStorageLocation =
        0x90cd26f58f230d7edce7681ec7052f8fcb3a4b7bd42b3fcbf2f239cce9d04d00;

    function _getBaseWithdrawerStorage() private pure returns (BaseWithdrawerStorage storage $) {
        assembly {
            $.slot := BaseWithdrawerStorageLocation
        }
    }

    modifier onlyWithdrawalRequest() {
        if (msg.sender != _getBaseWithdrawerStorage().withdrawalRequest) revert Unauthorized(msg.sender);
        _;
    }

    /// @notice Deploys a withdrawer bound to one vault and one withdrawal request contract.
    /// @param token_ Vault token to withdraw assets from.
    /// @param withdrawalRequest_ Withdrawal request contract authorized to call this withdrawer.
    constructor(address token_, address withdrawalRequest_) {
        if (token_ == address(0) || withdrawalRequest_ == address(0)) revert ZeroAddress();

        BaseWithdrawerStorage storage $ = _getBaseWithdrawerStorage();
        $.token = IVault(token_);
        $.withdrawalRequest = withdrawalRequest_;
    }

    /// @notice Forwards a withdrawal request to the configured vault.
    /// @param asset Asset to withdraw.
    /// @param assets Amount of `asset` to withdraw.
    /// @param receiver Receiver of the withdrawn asset.
    /// @param owner Owner whose shares are consumed.
    /// @return shares Amount of shares consumed by the vault.
    /// @dev When this withdrawer is used with BaseStrategy-backed vaults, grant it fee exemption
    /// and, depending on the vault configuration, potentially ALLOCATOR_ROLE.
    function withdrawAsset(uint256, address asset, uint256 assets, address receiver, address owner)
        external
        virtual
        onlyWithdrawalRequest
        returns (uint256 shares)
    {
        if (asset == address(token())) return _withdrawVaultToken(assets, receiver, owner);

        shares = token().withdrawAsset(asset, assets, receiver, owner);
    }

    /// @notice Converts shares to assets using the configured vault rate.
    /// @param shares Amount of shares to convert.
    /// @return assets Amount of assets represented by `shares`.
    function convertToAssets(uint256 shares) public view virtual returns (uint256 assets) {
        return token().convertToAssets(shares);
    }

    /// @notice Returns the vault token this withdrawer pulls assets from.
    /// @return The configured vault token.
    function token() public view returns (IVault) {
        return _getBaseWithdrawerStorage().token;
    }

    /// @notice Moves locked vault-token shares directly to the receiver without calling the vault.
    /// @dev Inheritors can use this to clear residual share dust or to support cancellation flows
    /// that return unredeemed vault-token shares to the request owner through the request bag.
    /// @param assets Amount of vault-token shares to transfer.
    /// @param receiver Receiver of the vault-token shares.
    /// @param owner Owner whose vault-token shares are transferred.
    /// @return shares Amount of vault-token shares consumed.
    function _withdrawVaultToken(uint256 assets, address receiver, address owner) internal returns (uint256 shares) {
        IERC20(address(token())).safeTransferFrom(owner, receiver, assets);
        return assets;
    }

    /// @notice Returns the withdrawal request contract authorized to call this withdrawer.
    /// @return The authorized withdrawal request contract.
    function withdrawalRequest() public view returns (address) {
        return _getBaseWithdrawerStorage().withdrawalRequest;
    }
}
