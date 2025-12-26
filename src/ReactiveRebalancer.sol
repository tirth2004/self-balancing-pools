// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./AbstractReactive.sol";
import "./IReactive.sol";

contract ReactiveRebalancer is AbstractReactive {
    uint256 public immutable sepoliaChainId;
    address public immutable poolA;
    address public immutable poolB;
    address public immutable sampler;
    address public immutable callback; // Sepolia callback contract (VaultCallback)

    // threshold in "rateRayPerSecond" units
    uint256 public threshold;

    bytes32 public constant RATE_UPDATED_SIG =
        keccak256("RateUpdated(uint256)");
    bytes32 public constant RATES_SAMPLED_SIG =
        keccak256("RatesSampled(uint256,uint256,uint256)");

    constructor(
        address _service, // Reactive system contract (Lasna)
        uint256 _sepoliaChainId, // 11155111
        address _poolA,
        address _poolB,
        address _sampler,
        address _callback,
        uint256 _threshold
    ) {
        service = ISystemContract(payable(_service));
        sepoliaChainId = _sepoliaChainId;
        poolA = _poolA;
        poolB = _poolB;
        sampler = _sampler;
        callback = _callback;
        threshold = _threshold;
    }

    receive() external payable {}

    function setThreshold(uint256 t) external authorizedSenderOnly {
        threshold = t;
    }

    function subscribeAll() external authorizedSenderOnly {
        // Subscribe to pool RateUpdated(uint256) events
        service.subscribe(
            sepoliaChainId,
            poolA,
            uint256(RATE_UPDATED_SIG),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        service.subscribe(
            sepoliaChainId,
            poolB,
            uint256(RATE_UPDATED_SIG),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        // Subscribe to sampler RatesSampled(uint256,uint256,uint256)
        service.subscribe(
            sepoliaChainId,
            sampler,
            uint256(RATES_SAMPLED_SIG),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 /* topic_1 */,
        uint256 /* topic_2 */,
        uint256 /* topic_3 */,
        bytes calldata data,
        uint256 /* block_number */,
        uint256 /* op_code */
    ) external override sysConOnly {
        if (chain_id != sepoliaChainId) return;

        // 1) If RateUpdated fired on either pool -> ask Sepolia to sample rates (emit RatesSampled)
        if (
            (_contract == poolA || _contract == poolB) &&
            topic_0 == uint256(RATE_UPDATED_SIG)
        ) {
            _emitCallbackSample();
            return;
        }

        // 2) If RatesSampled fired -> compare and possibly rebalance
        if (_contract == sampler && topic_0 == uint256(RATES_SAMPLED_SIG)) {
            (uint256 rateA, uint256 rateB, uint256 ts) = abi.decode(
                data,
                (uint256, uint256, uint256)
            );
            ts; // silence unused var if you don't need it

            uint256 diff = rateA > rateB ? (rateA - rateB) : (rateB - rateA);
            if (diff < threshold) return;

            uint8 winner = rateA >= rateB ? 0 : 1;
            _emitCallbackRebalanceAllTo(winner);
        }
    }

    function _emitCallbackSample() internal {
        // First arg is reserved for RVM ID (Reactive overwrites it), so we pass address(0)
        bytes memory payload = abi.encodeWithSignature(
            "sample(address)",
            address(0)
        );
        emit Callback(sepoliaChainId, callback, 400_000, payload);
    }

    function _emitCallbackRebalanceAllTo(uint8 toPool) internal {
        bytes memory payload = abi.encodeWithSignature(
            "rebalanceAllTo(address,uint8)",
            address(0),
            toPool
        );
        emit Callback(sepoliaChainId, callback, 800_000, payload);
    }
}
