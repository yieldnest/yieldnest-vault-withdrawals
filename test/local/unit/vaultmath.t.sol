// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IProvider} from "lib/yieldnest-vault/src/interface/IProvider.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {VaultMath} from "src/library/VaultMath.sol";
import {SetupWithdrawalRequest} from "test/local/unit/helpers/SetupWithdrawalRequest.sol";

contract VaultMathHarness {
    function convertToAssets(IVault token, address asset, uint256 shares) external view returns (uint256) {
        return VaultMath.convertToAssets(token, asset, shares);
    }
}

contract VaultMathTest is SetupWithdrawalRequest {
    using Math for uint256;

    VaultMathHarness internal harness;

    function setUp() public {
        setUpWithdrawalRequest();
        harness = new VaultMathHarness();
    }

    function testConvertToAssetsReturnsZeroForZeroShares() public view {
        assertEq(harness.convertToAssets(ynToken, address(asset), 0), 0);
    }

    function testConvertToAssetsMatchesVaultDefaultAssetConversion() public view {
        uint256 shares = 10 ether;

        assertEq(harness.convertToAssets(ynToken, address(asset), shares), ynToken.convertToAssets(shares));
    }

    function testConvertToAssetsUsesRequestedAssetRate() public {
        _setAssetRate(address(secondAsset), 2 ether);
        ynToken.processAccounting();

        uint256 shares = 10 ether;
        uint256 expected = _expectedConvertToAssets(address(secondAsset), shares);

        assertEq(harness.convertToAssets(ynToken, address(secondAsset), shares), expected);
    }

    function testConvertToAssetsReflectsYieldAccrualAfterAccounting() public {
        uint256 beforeAssets = harness.convertToAssets(ynToken, address(asset), 10 ether);

        asset.mint(address(ynToken), 10 ether);
        ynToken.processAccounting();

        uint256 afterAssets = harness.convertToAssets(ynToken, address(asset), 10 ether);

        assertGt(afterAssets, beforeAssets);
        assertEq(afterAssets, _expectedConvertToAssets(address(asset), 10 ether));
    }

    function testConvertToAssetsRoundsDown() public {
        _setAssetRate(address(secondAsset), 3 ether);
        ynToken.processAccounting();

        IVault.AssetParams memory assetParams = ynToken.getAsset(address(secondAsset));
        uint256 rate = IProvider(ynToken.provider()).getRate(address(secondAsset));

        bool foundRoundingCase;
        for (uint256 shares = 1; shares <= 100; ++shares) {
            uint256 baseAssets =
                shares.mulDiv(ynToken.totalBaseAssets() + 1, ynToken.totalSupply() + 1, Math.Rounding.Floor);
            uint256 roundedDown = baseAssets.mulDiv(10 ** assetParams.decimals, rate, Math.Rounding.Floor);
            uint256 roundedUp = baseAssets.mulDiv(10 ** assetParams.decimals, rate, Math.Rounding.Ceil);
            if (roundedDown == roundedUp) continue;

            assertEq(harness.convertToAssets(ynToken, address(secondAsset), shares), roundedDown);
            assertLt(roundedDown, roundedUp);
            foundRoundingCase = true;
            break;
        }

        assertTrue(foundRoundingCase);
    }

    function testFuzzConvertToAssetsMatchesFormula(uint128 shares, uint128 rewardAmount, uint96 rate) public {
        shares = uint128(bound(shares, 0, 100 ether));
        rewardAmount = uint128(bound(rewardAmount, 0, 100 ether));
        rate = uint96(bound(rate, 0.5 ether, 2 ether));

        if (rewardAmount != 0) asset.mint(address(ynToken), rewardAmount);
        _setAssetRate(address(secondAsset), rate);
        ynToken.processAccounting();

        assertEq(
            harness.convertToAssets(ynToken, address(secondAsset), shares),
            _expectedConvertToAssets(address(secondAsset), shares)
        );
    }

    function _expectedConvertToAssets(address asset_, uint256 shares) internal view returns (uint256) {
        uint256 baseAssets =
            shares.mulDiv(ynToken.totalBaseAssets() + 1, ynToken.totalSupply() + 1, Math.Rounding.Floor);
        IVault.AssetParams memory assetParams = ynToken.getAsset(asset_);
        uint256 rate = IProvider(ynToken.provider()).getRate(asset_);
        return baseAssets.mulDiv(10 ** assetParams.decimals, rate, Math.Rounding.Floor);
    }
}
