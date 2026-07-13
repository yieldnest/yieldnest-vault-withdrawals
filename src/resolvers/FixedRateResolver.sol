// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {BaseRateResolver} from "src/resolvers/BaseRateResolver.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";

/// @title FixedRateResolver
/// @notice Resolver that charges fees so resolutions happen at one configured vault share rate.
contract FixedRateResolver is BaseRateResolver {
    uint256 public immutable fixedRate;

    constructor(WithdrawalRequest withdrawalRequest_, address defaultAdmin, address resolver, uint256 fixedRate_)
        BaseRateResolver(withdrawalRequest_, defaultAdmin, resolver)
    {
        if (fixedRate_ == 0) revert InvalidRate();
        fixedRate = fixedRate_;
    }

    function _resolutionRate(uint256) internal view override returns (uint256) {
        return fixedRate;
    }
}
