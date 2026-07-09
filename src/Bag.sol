// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IBag} from "src/interface/IBag.sol";
import {IAuth} from "src/interface/IAuth.sol";

/// @title Bag
/// @notice Per-request asset container whose request NFT owner or approved operator can claim received assets.
contract Bag is Initializable, IBag {
    using SafeERC20 for IERC20;
    using Address for address payable;

    string public constant VERSION = "0.1.0";
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @custom:storage-location erc7201:yieldnest.storage.bag
    struct BagStorage {
        IAuth ownerRegistry;
        uint256 id;
    }

    // keccak256(abi.encode(uint256(keccak256("yieldnest.storage.bag")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BagStorageLocation = 0x071f3a4d16087e1e1f84c52c1bb778f9b193bf90b68ac0d666520edb595cf100;

    function _getBagStorage() private pure returns (BagStorage storage $) {
        assembly {
            $.slot := BagStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyOwner() {
        BagStorage storage $ = _getBagStorage();
        if (!$.ownerRegistry.isAuthorized(msg.sender, $.id)) revert NotRequestOwner(msg.sender);
        _;
    }

    receive() external payable {}

    /// @notice Initializes the bag with the request NFT contract and request id.
    /// @param ownerRegistry_ Contract that reports request NFT ownership.
    /// @param id_ Withdrawal request id represented by this bag.
    function initialize(address ownerRegistry_, uint256 id_) external initializer {
        if (ownerRegistry_ == address(0)) revert ZeroAddress();

        BagStorage storage $ = _getBagStorage();
        $.ownerRegistry = IAuth(ownerRegistry_);
        $.id = id_;
    }

    /// @notice Returns the withdrawal request id represented by this bag.
    /// @return The withdrawal request id.
    function id() external view returns (uint256) {
        return _getBagStorage().id;
    }

    /// @notice Returns the contract that reports request NFT ownership.
    /// @return The request owner registry.
    function ownerRegistry() external view returns (address) {
        return address(_getBagStorage().ownerRegistry);
    }

    /// @notice Claims ERC20 assets and native ETH from this bag.
    /// @dev Use `NATIVE_ETH` as the asset address for native ETH.
    /// @param assets Assets to claim.
    /// @param recipient Receiver of the claimed assets.
    /// @param amounts Amounts to claim for each asset.
    /// @return amounts The amounts claimed.
    function claim(address[] calldata assets, address payable recipient, uint256[] calldata amounts)
        external
        onlyOwner
        returns (uint256[] memory)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (assets.length != amounts.length) revert InvalidArrayLength();

        for (uint256 i = 0; i < assets.length; ++i) {
            address asset = assets[i];
            if (asset == address(0)) revert ZeroAddress();

            uint256 amount = amounts[i];
            if (asset == NATIVE_ETH) {
                recipient.sendValue(amount);
                emit NativeClaimed(msg.sender, recipient, amount);
            } else {
                IERC20(asset).safeTransfer(recipient, amount);
                emit ERC20Claimed(msg.sender, recipient, asset, amount);
            }
        }

        return amounts;
    }

    /// @notice Claims an ERC721 token held by this bag.
    /// @param asset ERC721 asset to claim.
    /// @param recipient Receiver of the claimed token.
    /// @param tokenId Token id to claim.
    function claimERC721(address asset, address recipient, uint256 tokenId) external onlyOwner {
        if (asset == address(0) || recipient == address(0)) revert ZeroAddress();

        IERC721(asset).safeTransferFrom(address(this), recipient, tokenId);

        emit ERC721Claimed(msg.sender, recipient, asset, tokenId);
    }
}
