// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./AbstractCallback.sol";
import "./Vault4626Like.sol";
import "./RateSampler.sol";

contract VaultCallback is AbstractCallback {
    Vault4626Like public immutable vault;
    RateSampler public immutable sampler;

    constructor(
        address callbackSender,
        address _vault,
        address _sampler
    ) AbstractCallback(callbackSender) {
        vault = Vault4626Like(_vault);
        sampler = RateSampler(_sampler);
    }

    // Reactive calls this to force an on-chain sample
    function sample(
        address _rvm_id
    ) external authorizedSenderOnly rvmIdOnly(_rvm_id) {
        sampler.sample();
    }

    // Reactive calls this to rebalance ALL from loser -> winner
    function rebalanceAllTo(
        address _rvm_id,
        uint8 toPool
    ) external authorizedSenderOnly rvmIdOnly(_rvm_id) {
        require(toPool == 0 || toPool == 1, "BAD_POOL");
        uint8 fromPool = toPool == 0 ? 1 : 0;

        ILendingAdapter from = fromPool == 0
            ? vault.adapterA()
            : vault.adapterB();
        uint256 amt = from.totalUnderlying();
        if (amt == 0) return;

        vault.rebalance(fromPool, toPool, amt);
    }
}
