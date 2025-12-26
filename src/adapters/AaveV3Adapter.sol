// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20, ILendingAdapter} from "../Vault4626Like.sol";

interface IAavePool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function transferFrom(address, address, uint256) external returns (bool);
}

contract AaveV3Adapter is ILendingAdapter {
    address public immutable vault;
    address public immutable underlying;
    IAavePool public immutable pool;
    address public immutable aToken; // aToken for underlying in this market

    modifier onlyVault() {
        require(msg.sender == vault, "ONLY_VAULT");
        _;
    }

    constructor(
        address _vault,
        address _underlying,
        address _pool,
        address _aToken
    ) {
        require(
            _vault != address(0) &&
                _underlying != address(0) &&
                _pool != address(0) &&
                _aToken != address(0),
            "ZERO"
        );
        vault = _vault;
        underlying = _underlying;
        pool = IAavePool(_pool);
        aToken = _aToken;
    }

    function deposit(uint256 assets) external onlyVault {
        require(assets != 0, "ZERO_ASSETS");

        // pull underlying from vault (vault pre-approves adapter)
        _safeTransferFrom(underlying, vault, address(this), assets);

        // approve pool and supply on behalf of adapter (adapter receives aTokens)
        _safeApprove(underlying, address(pool), 0);
        _safeApprove(underlying, address(pool), assets);

        pool.supply(underlying, assets, address(this), 0);
    }

    function withdraw(uint256 assets) external onlyVault {
        require(assets != 0, "ZERO_ASSETS");

        // withdraw underlying from Aave to adapter, then send to vault
        pool.withdraw(underlying, assets, address(this));
        _safeTransfer(underlying, vault, assets);
    }

    // aToken balance tracks principal + interest; treat as underlying amount for MVP
    function totalUnderlying() external view returns (uint256) {
        return IERC20Like(aToken).balanceOf(address(this));
    }

    function _safeTransferFrom(
        address t,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = t.call(
            abi.encodeWithSelector(
                IERC20Like.transferFrom.selector,
                from,
                to,
                amount
            )
        );
        require(
            ok && (data.length == 0 || abi.decode(data, (bool))),
            "TF_FROM_FAIL"
        );
    }

    function _safeTransfer(address t, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = t.call(
            abi.encodeWithSelector(IERC20Like.transfer.selector, to, amount)
        );
        require(
            ok && (data.length == 0 || abi.decode(data, (bool))),
            "TF_FAIL"
        );
    }

    function _safeApprove(address t, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = t.call(
            abi.encodeWithSelector(IERC20Like.approve.selector, spender, amount)
        );
        require(
            ok && (data.length == 0 || abi.decode(data, (bool))),
            "APPROVE_FAIL"
        );
    }
}
