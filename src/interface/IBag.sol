// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

interface IBag {
    error ZeroAddress();
    error NotRequestOwner(address caller);
    error InvalidArrayLength();

    event ERC20Claimed(address indexed owner, address indexed recipient, address indexed asset, uint256 amount);
    event ERC721Claimed(address indexed owner, address indexed recipient, address indexed asset, uint256 tokenId);
    event NativeClaimed(address indexed owner, address indexed recipient, uint256 amount);

    function VERSION() external view returns (string memory);
    function ETH() external view returns (address);
    function id() external view returns (uint256);
    function ownerRegistry() external view returns (address);
    function initialize(address ownerRegistry_, uint256 id_) external;
    function claim(address[] calldata assets, address payable recipient, uint256[] calldata amounts)
        external
        returns (uint256[] memory);
    function claimERC721(address asset, address recipient, uint256 tokenId) external;
}
