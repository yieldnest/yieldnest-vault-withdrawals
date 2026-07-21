// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "lib/yieldnest-vault/src/interface/IVault.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {LiveRateWithdrawer} from "src/withdrawers/LiveRateWithdrawer.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract MockWithdrawAssetVault is ERC20 {
    using SafeERC20 for IERC20;

    uint256 public burnMultiplier = 1;
    uint256 public returnAmountOffset;
    uint256 public transferShortfall;
    uint256 public convertToAssetsRate = 1 ether;
    address[] internal assetList;

    constructor() ERC20("ynToken", "ynT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setBurnMultiplier(uint256 burnMultiplier_) external {
        burnMultiplier = burnMultiplier_;
    }

    function setReturnAmountOffset(uint256 returnAmountOffset_) external {
        returnAmountOffset = returnAmountOffset_;
    }

    function setTransferShortfall(uint256 transferShortfall_) external {
        transferShortfall = transferShortfall_;
    }

    function setConvertToAssetsRate(uint256 convertToAssetsRate_) external {
        convertToAssetsRate = convertToAssetsRate_;
    }

    function setAssets(address[] memory assets_) external {
        delete assetList;
        for (uint256 i = 0; i < assets_.length; ++i) {
            assetList.push(assets_[i]);
        }
    }

    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        shares = assets * burnMultiplier;
        _burn(owner, shares);
        IERC20(asset_).safeTransfer(receiver, assets - transferShortfall);

        shares += returnAmountOffset;
    }

    function totalBaseAssets() external view returns (uint256) {
        return totalSupply();
    }

    function provider() external view returns (address) {
        return address(this);
    }

    function getAsset(address) external pure returns (IVault.AssetParams memory) {
        return IVault.AssetParams({index: 0, active: true, decimals: 18});
    }

    function getAssets() external view returns (address[] memory) {
        return assetList;
    }

    function asset() external view returns (address) {
        return assetList[0];
    }

    function getRate(address) external pure returns (uint256) {
        return 1 ether;
    }

    function convertToAssets(uint256 shares) external view returns (uint256 assets) {
        return shares * convertToAssetsRate / 1 ether;
    }
}

contract WithdrawalAssetMock is ERC20 {
    constructor() ERC20("Asset", "AST") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract SetupWithdrawalRequest is Test {
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    WithdrawalRequest manager;
    MockWithdrawAssetVault ynToken;
    WithdrawalAssetMock asset;
    WithdrawalAssetMock secondAsset;
    WithdrawalRequestViewer viewer;
    LiveRateWithdrawer withdrawer;
    MinAmountRequestPolicy requestPolicy;
    Bag bagImplementation;
    BeaconProxyFactory bagFactoryImplementation;
    BeaconProxyFactory bagFactory;

    address admin = address(0xA11CE);
    address resolver = address(0xF0111);
    address configurationManager = address(0xC0F16);
    address pauser = address(0xAA05E);
    address user = address(0xB0B);
    address receiver = address(0xCA11);
    address collector = address(0xC011EC7);
    uint256 minWithdrawalAmount = 1 ether;

    function setUpWithdrawalRequest() public virtual {
        ynToken = new MockWithdrawAssetVault();
        asset = new WithdrawalAssetMock();
        secondAsset = new WithdrawalAssetMock();
        viewer = new WithdrawalRequestViewer();
        bagImplementation = new Bag();
        bagFactoryImplementation = new BeaconProxyFactory();
        ERC1967Proxy bagFactoryProxy = new ERC1967Proxy(
            address(bagFactoryImplementation),
            abi.encodeCall(BeaconProxyFactory.initialize, (address(bagImplementation), admin, admin, admin))
        );
        bagFactory = BeaconProxyFactory(address(bagFactoryProxy));

        WithdrawalRequest implementation = new WithdrawalRequest();
        address predictedManager = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        withdrawer = new LiveRateWithdrawer(address(ynToken), predictedManager);
        requestPolicy = new MinAmountRequestPolicy(minWithdrawalAmount);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                WithdrawalRequest.initialize,
                (
                    address(ynToken),
                    admin,
                    resolver,
                    configurationManager,
                    pauser,
                    address(bagFactory),
                    address(withdrawer),
                    address(requestPolicy)
                )
            )
        );
        manager = WithdrawalRequest(address(proxy));

        bytes32 creatorRole = bagFactory.CREATOR_ROLE();
        vm.prank(admin);
        bagFactory.grantRole(creatorRole, address(manager));

        ynToken.mint(user, 100 ether);
        asset.mint(address(ynToken), 100 ether);
        secondAsset.mint(address(ynToken), 100 ether);

        address[] memory assets = new address[](2);
        assets[0] = address(asset);
        assets[1] = address(secondAsset);
        ynToken.setAssets(assets);

        vm.prank(user);
        ynToken.approve(address(manager), type(uint256).max);
    }
}
