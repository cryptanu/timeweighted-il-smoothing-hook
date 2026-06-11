// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library TenureLib {
    struct TierConfig {
        uint256 tier0Duration;
        uint256 tier1Duration;
        uint256 tier2Duration;
        uint256 tier0Factor;
        uint256 tier1Factor;
        uint256 tier2Factor;
        uint256 tier3Factor;
        uint256 reserveFeeShare;
    }

    error InvalidTierConfig();

    function validate(TierConfig memory config) internal pure {
        if (config.tier0Duration >= config.tier1Duration) revert InvalidTierConfig();
        if (config.tier1Duration >= config.tier2Duration) revert InvalidTierConfig();
        if (config.tier3Factor > 10_000 || config.reserveFeeShare > 10_000) revert InvalidTierConfig();
    }

    function factor(TierConfig memory config, uint256 entryTimestamp, uint256 nowTimestamp)
        internal
        pure
        returns (uint256)
    {
        if (nowTimestamp < entryTimestamp) return config.tier0Factor;
        uint256 tenure = nowTimestamp - entryTimestamp;
        if (tenure <= config.tier0Duration) return config.tier0Factor;
        if (tenure <= config.tier1Duration) return config.tier1Factor;
        if (tenure <= config.tier2Duration) return config.tier2Factor;
        return config.tier3Factor;
    }
}

