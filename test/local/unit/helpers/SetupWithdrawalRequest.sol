// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Vault} from "lib/yieldnest-vault/src/Vault.sol";
import {Bag} from "src/Bag.sol";
import {BeaconProxyFactory} from "src/BeaconProxyFactory.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";
import {BaseWithdrawer} from "src/withdrawers/BaseWithdrawer.sol";
import {WithdrawalRequestViewer} from "views/WithdrawalRequestViewer.sol";

contract WithdrawalAssetMock is ERC20 {
    constructor() ERC20("Asset", "AST") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract TestRateProvider {
    mapping(address asset => uint256 rate) public rates;

    function setRate(address asset, uint256 rate) external {
        rates[asset] = rate;
    }

    function getRate(address asset) external view returns (uint256) {
        uint256 rate = rates[asset];
        return rate == 0 ? 1 ether : rate;
    }
}

contract SetupWithdrawalRequest is Test {
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    WithdrawalRequest manager;
    Vault ynToken;
    WithdrawalAssetMock asset;
    WithdrawalAssetMock secondAsset;
    TestRateProvider rateProvider;
    WithdrawalRequestViewer viewer;
    BaseWithdrawer withdrawer;
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
    uint256 maxDataLength = 1024;

    function setUpWithdrawalRequest() public virtual {
        asset = new WithdrawalAssetMock();
        secondAsset = new WithdrawalAssetMock();
        rateProvider = new TestRateProvider();
        ynToken = _deployVault();
        viewer = new WithdrawalRequestViewer();
        bagImplementation = new Bag();
        bagFactoryImplementation = new BeaconProxyFactory();
        TransparentUpgradeableProxy bagFactoryProxy = new TransparentUpgradeableProxy(
            address(bagFactoryImplementation),
            admin,
            abi.encodeCall(BeaconProxyFactory.initialize, (address(bagImplementation), admin, admin, admin))
        );
        bagFactory = BeaconProxyFactory(address(bagFactoryProxy));

        WithdrawalRequest implementation = new WithdrawalRequest();
        address predictedManager = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        withdrawer = _deployBaseWithdrawer(address(ynToken), predictedManager);
        requestPolicy = new MinAmountRequestPolicy(minWithdrawalAmount);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
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
                    address(requestPolicy),
                    maxDataLength
                )
            )
        );
        manager = WithdrawalRequest(address(proxy));

        vm.startPrank(admin);
        ynToken.grantRole(ynToken.ASSET_WITHDRAWER_ROLE(), address(withdrawer));
        vm.stopPrank();

        bytes32 creatorRole = bagFactory.CREATOR_ROLE();
        vm.prank(admin);
        bagFactory.grantRole(creatorRole, address(manager));

        _mintVaultShares(user, 100 ether);
        secondAsset.mint(address(ynToken), 100 ether);

        vm.prank(user);
        ynToken.approve(address(manager), type(uint256).max);
    }

    function _deployBaseWithdrawer(address token_, address withdrawalRequest_) internal returns (BaseWithdrawer) {
        BaseWithdrawer implementation = new BaseWithdrawer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation), admin, abi.encodeCall(BaseWithdrawer.initialize, (token_, withdrawalRequest_))
        );
        return BaseWithdrawer(address(proxy));
    }

    function _deployVault() internal returns (Vault vault) {
        Vault implementation = new Vault();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(Vault.initialize, (admin, "YieldNest Test Vault", "ynTEST", 18, 0, false, false, 0))
        );
        vault = Vault(payable(address(proxy)));

        rateProvider.setRate(address(asset), 1 ether);
        rateProvider.setRate(address(secondAsset), 1 ether);

        vm.startPrank(admin);
        vault.grantRole(vault.PROVIDER_MANAGER_ROLE(), admin);
        vault.grantRole(vault.ASSET_MANAGER_ROLE(), admin);
        vault.grantRole(vault.UNPAUSER_ROLE(), admin);
        vault.setProvider(address(rateProvider));
        vault.addAsset(address(asset), true);
        vault.addAsset(address(secondAsset), true);
        vault.unpause();
        vm.stopPrank();
    }

    function _mintVaultShares(address account, uint256 shares) internal {
        asset.mint(account, shares);
        vm.startPrank(account);
        asset.approve(address(ynToken), type(uint256).max);
        ynToken.depositAsset(address(asset), shares, account);
        vm.stopPrank();
    }

    function _setAssetRate(address asset_, uint256 rate) internal {
        rateProvider.setRate(asset_, rate);
    }

    function _setDefaultAssetPerShare(uint256 assetsPerShare) internal {
        rateProvider.setRate(address(asset), 1 ether * 1 ether / assetsPerShare);
    }

    function _authorizeAssetWithdrawer(address assetWithdrawer) internal {
        vm.startPrank(admin);
        ynToken.grantRole(ynToken.ASSET_WITHDRAWER_ROLE(), assetWithdrawer);
        vm.stopPrank();
    }
}
