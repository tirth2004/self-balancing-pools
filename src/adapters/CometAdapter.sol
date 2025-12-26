// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILendingAdapter} from "../Vault4626Like.sol";

interface IComet {
    function supply(address asset, uint256 amount) external;

    function withdraw(address asset, uint256 amount) external;

    function balanceOf(address owner) external view returns (uint256);

    function baseToken() external view returns (address);

    function getUtilization() external view returns (uint256);

    function getSupplyRate(uint256 utilization) external view returns (uint64);
}

interface IERC20Like {
    function approve(address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function transferFrom(address, address, uint256) external returns (bool);
}

contract CometAdapter is ILendingAdapter {
    address public immutable vault;
    IComet public immutable comet;
    address public immutable underlying; // must be comet.baseToken()

    modifier onlyVault() {
        require(msg.sender == vault, "ONLY_VAULT");
        _;
    }

    constructor(address _vault, address _comet) {
        require(_vault != address(0) && _comet != address(0), "ZERO");
        vault = _vault;
        comet = IComet(_comet);
        underlying = comet.baseToken();
    }

    function deposit(uint256 assets) external onlyVault {
        require(assets != 0, "ZERO_ASSETS");

        _safeTransferFrom(underlying, vault, address(this), assets);

        _safeApprove(underlying, address(comet), 0);
        _safeApprove(underlying, address(comet), assets);

        comet.supply(underlying, assets);
    }

    function withdraw(uint256 assets) external onlyVault {
        require(assets != 0, "ZERO_ASSETS");

        comet.withdraw(underlying, assets);
        _safeTransfer(underlying, vault, assets);
    }

    // MVP assumption: Comet balanceOf reflects base asset claim (good enough for demo)
    function totalUnderlying() external view returns (uint256) {
        return comet.balanceOf(address(this));
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
