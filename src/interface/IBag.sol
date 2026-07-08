// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC721Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Metadata.sol";

interface IBag is IERC721Metadata {
    error ZeroAddress();
    error NotBagOwner(address caller);
    error InvalidArrayLength();

    event ERC20Claimed(address indexed owner, address indexed recipient, address indexed asset, uint256 amount);
    event ERC721Claimed(address indexed owner, address indexed recipient, address indexed asset, uint256 tokenId);
    event NativeClaimed(address indexed owner, address indexed recipient, uint256 amount);

    function VERSION() external view returns (string memory);
    function TOKEN_ID() external view returns (uint256);
    function NATIVE_ETH() external view returns (address);
    function id() external view returns (uint256);
    function initialize(address owner_, uint256 id_) external;
    function claim(address[] calldata assets, address payable recipient, uint256[] calldata amounts)
        external
        returns (uint256[] memory);
    function claimERC721(address asset, address recipient, uint256 tokenId) external;
}
