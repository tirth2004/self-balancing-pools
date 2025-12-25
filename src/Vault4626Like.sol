// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*//////////////////////////////////////////////////////////////
                             ERC20
  Minimal ERC20 (no OZ dependency) for vault shares.
//////////////////////////////////////////////////////////////*/

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ZERO_TO");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "BAL");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ZERO_TO");
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "BAL");
        unchecked {
            balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }
}

/*//////////////////////////////////////////////////////////////
                           IERC20
//////////////////////////////////////////////////////////////*/
interface IERC20 {
    function balanceOf(address) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);
}

/*//////////////////////////////////////////////////////////////
                        Lending Adapter
  Later we'll implement AaveAdapter + CometAdapter to match this.
//////////////////////////////////////////////////////////////*/
interface ILendingAdapter {
    // Vault calls these (adapter should restrict to vault).
    function deposit(uint256 assets) external;

    function withdraw(uint256 assets) external;

    // How much underlying is currently deployed via this adapter (in underlying units).
    function totalUnderlying() external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
                     Vault (ERC4626-like)
//////////////////////////////////////////////////////////////*/
contract Vault4626Like is ERC20 {
    IERC20 public immutable asset;

    ILendingAdapter public adapterA;
    ILendingAdapter public adapterB;

    address public owner;
    address public rebalancer; // Reactive callback contract / keeper
    bool public paused;

    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event AdaptersUpdated(address indexed adapterA, address indexed adapterB);
    event RebalancerUpdated(address indexed rebalancer);
    event Paused(bool paused);
    event Allocate(uint8 indexed toPool, uint256 assets);
    event Rebalanced(
        uint8 indexed fromPool,
        uint8 indexed toPool,
        uint256 assets
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyRebalancer() {
        require(msg.sender == rebalancer, "NOT_REBALANCER");
        _;
    }

    modifier notPaused() {
        require(!paused, "PAUSED");
        _;
    }

    constructor(
        address _asset,
        string memory _shareName,
        string memory _shareSymbol,
        uint8 _shareDecimals
    ) ERC20(_shareName, _shareSymbol, _shareDecimals) {
        require(_asset != address(0), "ZERO_ASSET");
        asset = IERC20(_asset);
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                              Admin
    //////////////////////////////////////////////////////////////*/

    function setAdapters(address _a, address _b) external onlyOwner {
        adapterA = ILendingAdapter(_a);
        adapterB = ILendingAdapter(_b);
        emit AdaptersUpdated(_a, _b);
    }

    function setRebalancer(address _rebalancer) external onlyOwner {
        rebalancer = _rebalancer;
        emit RebalancerUpdated(_rebalancer);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC4626-like views
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        uint256 a = address(adapterA) == address(0)
            ? 0
            : adapterA.totalUnderlying();
        uint256 b = address(adapterB) == address(0)
            ? 0
            : adapterB.totalUnderlying();
        return bal + a + b;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets; // 1:1 bootstrap
        uint256 ta = totalAssets();
        // shares = assets * supply / totalAssets
        return (assets * supply) / ta;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        uint256 ta = totalAssets();
        // assets = shares * totalAssets / supply
        return (shares * ta) / supply;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        uint256 ta = totalAssets();
        // shares = ceil(assets * supply / ta)
        return _divUp(assets * supply, ta);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                           User actions
    //////////////////////////////////////////////////////////////*/

    function deposit(
        uint256 assets,
        address receiver
    ) external notPaused returns (uint256 shares) {
        require(receiver != address(0), "ZERO_RECEIVER");
        require(assets != 0, "ZERO_ASSETS");

        shares = convertToShares(assets);
        require(shares != 0, "ZERO_SHARES");

        _safeTransferFrom(asset, msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) external notPaused returns (uint256 assets) {
        require(receiver != address(0), "ZERO_RECEIVER");
        require(shares != 0, "ZERO_SHARES");

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "ALLOWANCE");
                allowance[owner_][msg.sender] = allowed - shares;
                emit Approval(
                    owner_,
                    msg.sender,
                    allowance[owner_][msg.sender]
                );
            }
        }

        assets = convertToAssets(shares);
        _ensureLiquidity(assets);

        _burn(owner_, shares);
        _safeTransfer(asset, receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) external notPaused returns (uint256 shares) {
        require(receiver != address(0), "ZERO_RECEIVER");
        require(assets != 0, "ZERO_ASSETS");

        shares = _divUp(assets * totalSupply, totalAssets());
        require(shares != 0, "ZERO_SHARES");

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "ALLOWANCE");
                allowance[owner_][msg.sender] = allowed - shares;
                emit Approval(
                    owner_,
                    msg.sender,
                    allowance[owner_][msg.sender]
                );
            }
        }

        _ensureLiquidity(assets);

        _burn(owner_, shares);
        _safeTransfer(asset, receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                         Allocation / Rebalance
      - allocate(): owner manual move (for testing/demo)
      - rebalance(): automation call (Reactive callback)
    //////////////////////////////////////////////////////////////*/

    // For manual testing: push idle funds into a pool
    function allocate(
        uint8 toPool,
        uint256 assets
    ) external onlyOwner notPaused {
        require(assets != 0, "ZERO_ASSETS");
        if (toPool == 0) {
            _depositTo(adapterA, assets);
        } else if (toPool == 1) {
            _depositTo(adapterB, assets);
        } else {
            revert("BAD_POOL");
        }
        emit Allocate(toPool, assets);
    }

    // Called by your Reactive callback contract/keeper
    function rebalance(
        uint8 fromPool,
        uint8 toPool,
        uint256 assets
    ) external onlyRebalancer notPaused {
        require(fromPool != toPool, "SAME_POOL");
        require(assets != 0, "ZERO_ASSETS");

        ILendingAdapter from = (fromPool == 0) ? adapterA : adapterB;
        ILendingAdapter to = (toPool == 0) ? adapterA : adapterB;

        require(
            address(from) != address(0) && address(to) != address(0),
            "ADAPTER_ZERO"
        );

        from.withdraw(assets); // should send underlying back to vault
        _depositTo(to, assets);

        emit Rebalanced(fromPool, toPool, assets);
    }

    /*//////////////////////////////////////////////////////////////
                          Internal helpers
    //////////////////////////////////////////////////////////////*/

    function _ensureLiquidity(uint256 needed) internal {
        uint256 bal = asset.balanceOf(address(this));
        if (bal >= needed) return;

        uint256 shortfall = needed - bal;

        // Try to pull from A then B (simple & deterministic).
        if (address(adapterA) != address(0)) {
            uint256 a = adapterA.totalUnderlying();
            uint256 take = a < shortfall ? a : shortfall;
            if (take != 0) adapterA.withdraw(take);
            bal = asset.balanceOf(address(this));
            if (bal >= needed) return;
            shortfall = needed - bal;
        }

        if (address(adapterB) != address(0)) {
            uint256 b = adapterB.totalUnderlying();
            uint256 take = b < shortfall ? b : shortfall;
            if (take != 0) adapterB.withdraw(take);
        }

        require(asset.balanceOf(address(this)) >= needed, "INSUFFICIENT_LIQ");
    }

    function _depositTo(ILendingAdapter adapter, uint256 assets) internal {
        require(address(adapter) != address(0), "ADAPTER_ZERO");

        // approve-reset pattern for safety with some tokens
        _safeApprove(asset, address(adapter), 0);
        _safeApprove(asset, address(adapter), assets);

        adapter.deposit(assets);
    }

    function _safeTransferFrom(
        IERC20 t,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = address(t).call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
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

    function _safeTransfer(IERC20 t, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(t).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(
            ok && (data.length == 0 || abi.decode(data, (bool))),
            "TF_FAIL"
        );
    }

    function _safeApprove(IERC20 t, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = address(t).call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, amount)
        );
        require(
            ok && (data.length == 0 || abi.decode(data, (bool))),
            "APPROVE_FAIL"
        );
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }
}
