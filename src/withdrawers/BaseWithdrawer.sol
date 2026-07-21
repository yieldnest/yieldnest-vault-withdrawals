// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IWithdrawer} from "src/interface/IWithdrawer.sol";
import {IWithdrawerVault} from "src/interface/IWithdrawerVault.sol";

/// @title BaseWithdrawer
/// @notice Authorized adapter that forwards withdrawals to the configured vault at its live redemption rate.
contract BaseWithdrawer is IWithdrawer {
    /// @custom:storage-location erc7201:yieldnest.storage.base_withdrawer
    struct BaseWithdrawerStorage {
        IWithdrawerVault token;
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
        $.token = IWithdrawerVault(token_);
        $.withdrawalRequest = withdrawalRequest_;
    }

    /// @notice Forwards a withdrawal request to the configured vault.
    /// @param asset Asset to withdraw.
    /// @param assets Amount of `asset` to withdraw.
    /// @param receiver Receiver of the withdrawn asset.
    /// @param owner Owner whose shares are consumed.
    /// @return shares Amount of shares consumed by the vault.
    function withdrawAsset(uint256, address asset, uint256 assets, address receiver, address owner)
        external
        virtual
        onlyWithdrawalRequest
        returns (uint256 shares)
    {
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
    function token() public view returns (IWithdrawerVault) {
        return _getBaseWithdrawerStorage().token;
    }

    /// @notice Returns the withdrawal request contract authorized to call this withdrawer.
    /// @return The authorized withdrawal request contract.
    function withdrawalRequest() public view returns (address) {
        return _getBaseWithdrawerStorage().withdrawalRequest;
    }
}
