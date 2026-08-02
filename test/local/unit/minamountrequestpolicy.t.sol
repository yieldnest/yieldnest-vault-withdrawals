// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MinAmountRequestPolicy} from "src/policies/MinAmountRequestPolicy.sol";

contract MinAmountRequestPolicyTest is Test {
    address internal requester = address(0xA11CE);
    address internal receiver = address(0xB0B);
    uint256 internal minWithdrawalAmount = 1 ether;

    MinAmountRequestPolicy internal policy;

    function setUp() public {
        policy = new MinAmountRequestPolicy(minWithdrawalAmount);
    }

    function testConstructorSetsMinimumWithdrawalAmount() public view {
        assertEq(policy.minWithdrawalAmount(), minWithdrawalAmount);
    }

    function testValidateRequestAllowsAmountEqualToMinimum() public view {
        policy.validateRequest(requester, receiver, minWithdrawalAmount, "");
    }

    function testValidateRequestAllowsAmountAboveMinimum() public view {
        policy.validateRequest(requester, receiver, minWithdrawalAmount + 1, abi.encode("metadata"));
    }

    function testValidateRequestRevertsBelowMinimum() public {
        uint256 amount = minWithdrawalAmount - 1;

        vm.expectRevert(
            abi.encodeWithSelector(MinAmountRequestPolicy.AmountBelowMinimum.selector, amount, minWithdrawalAmount)
        );
        policy.validateRequest(requester, receiver, amount, "");
    }

    function testValidateRequestAllowsZeroWhenMinimumIsZero() public {
        MinAmountRequestPolicy zeroMinPolicy = new MinAmountRequestPolicy(0);
        zeroMinPolicy.validateRequest(address(0), address(0), 0, hex"deadbeef");
    }
}
