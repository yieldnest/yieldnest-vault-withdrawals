// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title InspectProxyAdmins
 * @notice Prints on-chain admins and their owners for the three withdrawal system proxies.
 * @dev Run with --rpc-url. Reads storage with vm.load; never broadcasts transactions.
 */
contract InspectProxyAdmins is Script {
    /**
     * @notice Inspects the current ynRWAx deployment.
     */
    function run() external view {
        _inspect(string.concat(vm.projectRoot(), "/deployments/withdrawalRequest-ynRWAx-1.json"));
    }

    /**
     * @notice Inspects a specified deployment file.
     * @param deploymentFile Path to the deployment JSON.
     */
    function inspect(string calldata deploymentFile) external view {
        _inspect(deploymentFile);
    }

    function _inspect(string memory deploymentFile) internal view {
        string memory json = vm.readFile(deploymentFile);
        console2.log("Deployment:", deploymentFile);
        console2.log("Chain ID:", block.chainid);
        console2.log("Block:", block.number);

        _printProxyAdmin("WithdrawalRequest proxy", vm.parseJsonAddress(json, ".proxy"));
        _printProxyAdmin("Bag factory proxy", vm.parseJsonAddress(json, ".bagFactoryProxy"));
        _printProxyAdmin("Withdrawer proxy", vm.parseJsonAddress(json, ".withdrawerProxy"));
    }

    function _printProxyAdmin(string memory label, address proxy) internal view {
        require(proxy.code.length != 0, "Proxy has no code");
        address admin = address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT))));
        require(admin != address(0), "Proxy admin slot is empty");

        console2.log("");
        console2.log(label, proxy);
        console2.log("  Proxy admin:", admin);
        console2.log("  Proxy admin owner:", Ownable(admin).owner());
    }
}
