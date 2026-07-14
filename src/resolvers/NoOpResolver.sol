// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {BaseResolver} from "src/resolvers/BaseResolver.sol";
import {WithdrawalRequest} from "src/WithdrawalRequest.sol";

/// @title NoOpResolver
/// @notice Resolver adapter that forwards resolutions without charging a fee.
contract NoOpResolver is BaseResolver {
    constructor(WithdrawalRequest withdrawalRequest_, address defaultAdmin, address resolver)
        BaseResolver(withdrawalRequest_, defaultAdmin, resolver)
    {}
}
