// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseRateResolver} from "src/resolvers/BaseRateResolver.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";

contract RequestRateResolver is BaseRateResolver {
    constructor(WithdrawalRequest withdrawalRequest_, address defaultAdmin, address resolver)
        BaseRateResolver(withdrawalRequest_, defaultAdmin, resolver)
    {}

    function _resolutionRate(uint256 id) internal view override returns (uint256) {
        return withdrawalRequest.requests(id).rateAtRequest;
    }
}
