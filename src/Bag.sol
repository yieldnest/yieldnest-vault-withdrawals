// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {ERC721Upgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IBag} from "src/interface/IBag.sol";

/// @title Bag
/// @notice Per-request NFT container whose token owner can claim received assets.
contract Bag is Initializable, ERC721Upgradeable, IBag {
    using SafeERC20 for IERC20;
    using Address for address payable;

    string public constant VERSION = "0.1.0";
    uint256 public constant TOKEN_ID = 1;

    /// @custom:storage-location erc7201:yieldnest.storage.bag
    struct BagStorage {
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

    modifier onlyNFTOwner() {
        if (msg.sender != ownerOf(TOKEN_ID)) revert NotBagOwner(msg.sender);
        _;
    }

    receive() external payable {}

    /// @notice Initializes the bag NFT and mints it to the owner.
    /// @param owner_ Initial owner of the bag NFT.
    /// @param id_ Withdrawal request id represented by this bag.
    function initialize(address owner_, uint256 id_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();

        _getBagStorage().id = id_;

        string memory idString = Strings.toString(id_);
        __ERC721_init(string.concat("YieldNest Withdrawal Bag #", idString), string.concat("ynBAG-", idString));
        _mint(owner_, TOKEN_ID);
    }

    /// @notice Returns the withdrawal request id represented by this bag.
    /// @return The withdrawal request id.
    function id() external view returns (uint256) {
        return _getBagStorage().id;
    }

    /// @notice Claims an amount of an ERC20 asset from this bag.
    /// @param asset Asset to claim.
    /// @param recipient Receiver of the claimed asset.
    /// @param amount Amount to claim.
    /// @return amount Amount claimed.
    function claimERC20(address asset, address recipient, uint256 amount) external onlyNFTOwner returns (uint256) {
        if (asset == address(0) || recipient == address(0)) revert ZeroAddress();

        IERC20(asset).safeTransfer(recipient, amount);

        emit ERC20Claimed(msg.sender, recipient, asset, amount);

        return amount;
    }

    /// @notice Claims an ERC721 token held by this bag.
    /// @param asset ERC721 asset to claim.
    /// @param recipient Receiver of the claimed token.
    /// @param tokenId Token id to claim.
    function claimERC721(address asset, address recipient, uint256 tokenId) external onlyNFTOwner {
        if (asset == address(0) || recipient == address(0)) revert ZeroAddress();

        IERC721(asset).safeTransferFrom(address(this), recipient, tokenId);

        emit ERC721Claimed(msg.sender, recipient, asset, tokenId);
    }

    /// @notice Claims an amount of native ETH from this bag.
    /// @param recipient Receiver of the claimed native ETH.
    /// @param amount Amount to claim.
    /// @return amount Amount claimed.
    function claimNative(address payable recipient, uint256 amount) external onlyNFTOwner returns (uint256) {
        if (recipient == address(0)) revert ZeroAddress();

        recipient.sendValue(amount);

        emit NativeClaimed(msg.sender, recipient, amount);

        return amount;
    }
}
