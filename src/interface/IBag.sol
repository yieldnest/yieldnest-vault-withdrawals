// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC721Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Enumerable} from "lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IBag is IERC721Metadata, IERC721Enumerable {
    error ZeroAddress();
    error NotBagOwner(address caller);

    event ERC20Claimed(address indexed owner, address indexed recipient, address indexed asset, uint256 amount);
    event ERC721Claimed(address indexed owner, address indexed recipient, address indexed asset, uint256 tokenId);
    event NativeClaimed(address indexed owner, address indexed recipient, uint256 amount);

    function VERSION() external view returns (string memory);
    function TOKEN_ID() external view returns (uint256);
    function id() external view returns (uint256);
    function initialize(address owner_, uint256 id_) external;
    function claimNative(address payable recipient, uint256 amount) external returns (uint256);
    function claimERC20(address asset, address recipient, uint256 amount) external returns (uint256);
    function claimERC721(address asset, address recipient, uint256 tokenId) external;
}
