// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IBag {
    error ZeroAddress();
    error NotRequestOwner(address caller);
    error InvalidArrayLength();

    event ERC20Claimed(address indexed owner, address indexed recipient, address indexed asset, uint256 amount);
    event ERC721Claimed(address indexed owner, address indexed recipient, address indexed asset, uint256 tokenId);
    event NativeClaimed(address indexed owner, address indexed recipient, uint256 amount);

    /// @notice Returns the Bag implementation version.
    function VERSION() external view returns (string memory);

    /// @notice Returns the sentinel address used to represent native ETH in claim calls.
    function ETH() external view returns (address);

    /// @notice Returns the withdrawal request id represented by this bag.
    function id() external view returns (uint256);

    /// @notice Returns the contract that reports request NFT ownership.
    function auth() external view returns (address);

    /// @notice Initializes the bag with its auth and request id.
    /// @param auth_ Contract that reports request NFT ownership.
    /// @param id_ Withdrawal request id represented by this bag.
    function initialize(address auth_, uint256 id_) external;

    /// @notice Claims ERC20 assets and native ETH from this bag.
    /// @param assets Assets to claim, using `ETH` for native ETH.
    /// @param recipient Receiver of the claimed assets.
    /// @param amounts Amounts to claim for each asset.
    /// @return Claimed amounts.
    function claim(address[] calldata assets, address payable recipient, uint256[] calldata amounts)
        external
        returns (uint256[] memory);

    /// @notice Claims an ERC721 token held by this bag.
    /// @param asset ERC721 asset to claim.
    /// @param recipient Receiver of the claimed token.
    /// @param tokenId Token id to claim.
    function claimERC721(address asset, address recipient, uint256 tokenId) external;
}
