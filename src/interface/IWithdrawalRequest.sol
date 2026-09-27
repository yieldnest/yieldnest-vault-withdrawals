// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IAuth} from "src/interface/IAuth.sol";
import {IFactory} from "src/interface/IFactory.sol";
import {IRequestPolicy} from "src/interface/IRequestPolicy.sol";
import {IResolver} from "src/interface/IResolver.sol";
import {IWithdrawer} from "src/interface/IWithdrawer.sol";
import {IWithdrawerVault} from "src/interface/IWithdrawerVault.sol";

interface IWithdrawalRequest is IAuth, IResolver {
    struct Request {
        address bag;
        uint256 amountLocked;
        address[] assetsRedeemed;
        uint256 rateAtRequest;
        bytes data;
    }

    struct InitializeParams {
        /// @notice yn-token shares locked and resolved by this contract.
        address token;
        /// @notice Request NFT name.
        string name;
        /// @notice Request NFT symbol.
        string symbol;
        /// @notice Account granted the default admin role.
        address defaultAdmin;
        /// @notice Account granted permission to resolve requests.
        address resolver;
        /// @notice Account granted permission to update configurable modules.
        address configurationManager;
        /// @notice Account granted permission to pause and unpause request creation.
        address pauser;
        /// @notice Factory used to deploy request bags.
        address bagFactory;
        /// @notice Adapter used to withdraw assets from the yn-token.
        address withdrawer;
        /// @notice Policy used to validate request creation.
        address requestPolicy;
        /// @notice Maximum bytes allowed in request metadata.
        uint256 maxDataLength;
    }

    error ZeroAddress();
    error ZeroAmount();
    error RequestNotFound(uint256 id);
    error InsufficientLockedAmount(uint256 id, uint256 amountLocked, uint256 amountBurned);
    error InvalidTokenBalanceChange(uint256 balanceBefore, uint256 balanceAfter);
    error ArrayLengthMismatch(uint256 assetsLength, uint256 assetAmountsLength);
    error DataTooLong(uint256 length, uint256 maxLength);
    error NotRequestOwner(address caller);
    error RequestNotBurnable(uint256 id);

    event WithdrawalRequested(
        uint256 indexed id, address indexed owner, address indexed token, address bag, uint256 amountLocked, bytes data
    );
    event WithdrawalRequestBurned(uint256 indexed id, address indexed owner, address bag);
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
    event MaxDataLengthUpdated(uint256 oldMaxDataLength, uint256 newMaxDataLength);

    function initialize(InitializeParams calldata params) external;

    function requestWithdrawal(uint256 amount, address receiver) external returns (uint256 id);

    function requestWithdrawal(uint256 amount, address receiver, bytes calldata data) external returns (uint256 id);

    function burn(uint256 id) external;

    function setWithdrawer(address withdrawer_) external;

    function setRequestPolicy(address requestPolicy_) external;

    function setMaxDataLength(uint256 maxDataLength_) external;

    function pause() external;

    function unpause() external;

    function VERSION() external view returns (string memory);

    function token() external view returns (IWithdrawerVault);

    function bagFactory() external view returns (IFactory);

    function withdrawer() external view returns (IWithdrawer);

    function nextRequestId() external view returns (uint256);

    function requestPolicy() external view returns (IRequestPolicy);

    function maxDataLength() external view returns (uint256);

    function requests(uint256 id) external view returns (Request memory);

    function requestExists(uint256 id) external view returns (bool);
}
