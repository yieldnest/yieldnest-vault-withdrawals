// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBag} from "src/interface/IBag.sol";
import {WithdrawalRequestManager} from "src/WithdrawalRequestManager.sol";

interface IWithdrawalRequestViewerVault is IERC20 {
    function getAssets() external view returns (address[] memory);
}

/// @title WithdrawalRequestViewer
/// @notice Read-only helper for request, bag, and vault asset balances.
contract WithdrawalRequestViewer {
    struct AssetBalance {
        address asset;
        uint256 balance;
    }

    struct RequestView {
        address owner;
        address bag;
        address token;
        uint256 amountLocked;
        uint256 tokenBalance;
        AssetBalance[] assetBalances;
    }

    function getRequest(WithdrawalRequestManager manager, uint256 id) external view returns (RequestView memory view_) {
        WithdrawalRequestManager.WithdrawalRequest memory request = manager.requests(id);
        IWithdrawalRequestViewerVault token = IWithdrawalRequestViewerVault(address(manager.token()));
        address[] memory assets = token.getAssets();

        AssetBalance[] memory assetBalances = new AssetBalance[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            assetBalances[i] = AssetBalance({asset: assets[i], balance: IERC20(assets[i]).balanceOf(request.bag)});
        }

        view_ = RequestView({
            owner: IBag(request.bag).ownerOf(IBag(request.bag).TOKEN_ID()),
            bag: request.bag,
            token: address(token),
            amountLocked: request.amountLocked,
            tokenBalance: token.balanceOf(address(manager)),
            assetBalances: assetBalances
        });
    }
}
