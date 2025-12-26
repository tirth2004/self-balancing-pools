// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRatePool {
    function getRateRayPerSecond() external view returns (uint256);
}

contract RateSampler {
    address public poolA;
    address public poolB;

    event RatesSampled(uint256 rateA, uint256 rateB, uint256 ts);

    constructor(address _poolA, address _poolB) {
        poolA = _poolA;
        poolB = _poolB;
    }

    function sample() external {
        uint256 a = IRatePool(poolA).getRateRayPerSecond();
        uint256 b = IRatePool(poolB).getRateRayPerSecond();
        emit RatesSampled(a, b, block.timestamp);
    }
}
