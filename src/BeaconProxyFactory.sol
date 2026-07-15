// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {
    AccessControlUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {BeaconProxy} from "lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IFactory} from "src/interface/IFactory.sol";

/// @title BeaconProxyFactory
/// @notice Shared beacon proxy factory and implementation upgrade manager.
contract BeaconProxyFactory is Initializable, AccessControlUpgradeable, IFactory {
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant IMPLEMENTATION_MANAGER_ROLE = keccak256("IMPLEMENTATION_MANAGER_ROLE");

    /// @custom:storage-location erc7201:yieldnest.storage.beacon_proxy_factory
    struct BeaconProxyFactoryStorage {
        UpgradeableBeacon beacon;
    }

    error ZeroAddress();

    event ProxyCreated(address indexed creator, address indexed proxy, address indexed implementation);
    event ImplementationUpgraded(address indexed previousImplementation, address indexed newImplementation);

    // keccak256(abi.encode(uint256(keccak256("yieldnest.storage.beacon_proxy_factory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BeaconProxyFactoryStorageLocation =
        0xac884db614a3a993e363c1354daa3ef0ad7667a4ab0ad3edaf953385bea78300;

    function _getBeaconProxyFactoryStorage() private pure returns (BeaconProxyFactoryStorage storage $) {
        assembly {
            $.slot := BeaconProxyFactoryStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address implementation_, address defaultAdmin, address creator, address implementationManager)
        external
        initializer
    {
        if (
            implementation_ == address(0) || defaultAdmin == address(0) || creator == address(0)
                || implementationManager == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(CREATOR_ROLE, creator);
        _grantRole(IMPLEMENTATION_MANAGER_ROLE, implementationManager);

        _getBeaconProxyFactoryStorage().beacon = new UpgradeableBeacon(implementation_, address(this));
    }

    /// @notice Creates a new beacon proxy initialized with arbitrary call data.
    /// @param initData Initialization call data for the implementation.
    /// @return proxy New proxy address.
    function create(bytes calldata initData) external override onlyRole(CREATOR_ROLE) returns (address proxy) {
        UpgradeableBeacon beacon_ = _getBeaconProxyFactoryStorage().beacon;
        address implementation_ = beacon_.implementation();
        proxy = address(new BeaconProxy(address(beacon_), initData));

        emit ProxyCreated(msg.sender, proxy, implementation_);
    }

    /// @notice Upgrades the implementation used by all proxies created by this factory.
    /// @param newImplementation New implementation address.
    function upgradeImplementation(address newImplementation) external onlyRole(IMPLEMENTATION_MANAGER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();

        UpgradeableBeacon beacon_ = _getBeaconProxyFactoryStorage().beacon;
        address previousImplementation = beacon_.implementation();
        beacon_.upgradeTo(newImplementation);

        emit ImplementationUpgraded(previousImplementation, newImplementation);
    }

    /// @notice Returns the beacon used by created proxies.
    /// @return The beacon address.
    function beacon() public view returns (address) {
        return address(_getBeaconProxyFactoryStorage().beacon);
    }

    /// @notice Returns the current implementation.
    /// @return The current implementation address.
    function implementation() public view returns (address) {
        return _getBeaconProxyFactoryStorage().beacon.implementation();
    }
}
