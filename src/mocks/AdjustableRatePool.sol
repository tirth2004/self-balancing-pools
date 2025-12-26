// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILendingAdapter, IERC20} from "../Vault4626Like.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract AdjustableRatePool is ILendingAdapter {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    IERC20 public immutable asset;
    address public immutable vault;
    address public owner;

    // per-second rate in RAY (1e27). Set via setAprWad.
    uint256 public rateRayPerSecond;

    // interest index in RAY
    uint256 public indexRay;
    uint40 public lastAccrual;

    mapping(address => uint256) public scaledBalance;
    uint256 public totalScaled;

    event RateUpdated(uint256 rateRayPerSecond);
    event Accrued(uint256 newIndexRay, uint256 mintedInterest);
    event Deposit(address indexed user, uint256 assets, uint256 scaled);
    event Withdraw(address indexed user, uint256 assets, uint256 scaled);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }
    modifier onlyVault() {
        require(msg.sender == vault, "ONLY_VAULT");
        _;
    }

    constructor(address _asset, address _vault) {
        require(_asset != address(0) && _vault != address(0), "ZERO");
        asset = IERC20(_asset);
        vault = _vault;
        owner = msg.sender;

        indexRay = RAY;
        lastAccrual = uint40(block.timestamp);
    }

    // APR in WAD (1e18). Example: 5% = 0.05e18
    function setAprWad(uint256 aprWad) external onlyOwner {
        rateRayPerSecond = (aprWad * (RAY / 1e18)) / SECONDS_PER_YEAR;
        emit RateUpdated(rateRayPerSecond);
    }

    function getRateRayPerSecond() external view returns (uint256) {
        return rateRayPerSecond;
    }

    function deposit(uint256 assets) external override onlyVault {
        require(assets != 0, "ZERO_ASSETS");
        _accrue();

        uint256 scaled = (assets * RAY) / indexRay;
        totalScaled += scaled;
        scaledBalance[vault] += scaled;

        _safeTransferFrom(address(asset), vault, address(this), assets);
        emit Deposit(vault, assets, scaled);
    }

    function withdraw(uint256 assets) external override onlyVault {
        require(assets != 0, "ZERO_ASSETS");
        _accrue();

        uint256 scaled = _divUp(assets * RAY, indexRay);
        uint256 bal = scaledBalance[vault];
        require(bal >= scaled, "INSUFFICIENT");

        unchecked {
            scaledBalance[vault] = bal - scaled;
            totalScaled -= scaled;
        }

        _ensureLiquidity(assets);
        _safeTransfer(address(asset), vault, assets);

        emit Withdraw(vault, assets, scaled);
    }

    function totalUnderlying() external view override returns (uint256) {
        (uint256 idx, ) = _previewAccrue();
        return (scaledBalance[vault] * idx) / RAY;
    }

    function _accrue() internal {
        (uint256 newIndex, uint256 interestToMint) = _previewAccrue();
        if (newIndex == indexRay) return;

        indexRay = newIndex;
        lastAccrual = uint40(block.timestamp);

        if (interestToMint != 0) {
            IMintable(address(asset)).mint(address(this), interestToMint);
        }
        emit Accrued(indexRay, interestToMint);
    }

    function _previewAccrue()
        internal
        view
        returns (uint256 newIndex, uint256 interestToMint)
    {
        uint256 dt = block.timestamp - uint256(lastAccrual);
        if (dt == 0 || rateRayPerSecond == 0) return (indexRay, 0);

        uint256 growthRay = rateRayPerSecond * dt;
        newIndex = indexRay + ((indexRay * growthRay) / RAY);

        uint256 oldU = (totalScaled * indexRay) / RAY;
        uint256 newU = (totalScaled * newIndex) / RAY;
        interestToMint = newU > oldU ? (newU - oldU) : 0;
    }

    function _ensureLiquidity(uint256 needed) internal {
        uint256 bal = asset.balanceOf(address(this));
        if (bal >= needed) return;
        IMintable(address(asset)).mint(address(this), needed - bal);
    }

    function _safeTransferFrom(
        address t,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = t.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
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
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(
            ok && (data.length == 0 || abi.decode(data, (bool))),
            "TF_FAIL"
        );
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }
}
