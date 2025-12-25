// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/Vault4626Like.sol";

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(
        address spender,
        uint256 amt
    ) external override returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(
        address to,
        uint256 amt
    ) external override returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amt
    ) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "ALLOW");
            allowance[from][msg.sender] = a - amt;
        }
        _transfer(from, to, amt);
        return true;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "BAL");
        unchecked {
            balanceOf[from] -= amt;
            balanceOf[to] += amt;
        }
    }
}

contract MockAdapter is ILendingAdapter {
    IERC20 public immutable asset;
    address public immutable vault;

    constructor(address _asset, address _vault) {
        asset = IERC20(_asset);
        vault = _vault;
    }

    function deposit(uint256 assets) external override {
        require(msg.sender == vault, "ONLY_VAULT");
        // pull from vault into adapter
        bool ok = asset.transferFrom(vault, address(this), assets);
        require(ok, "TF_FROM");
    }

    function withdraw(uint256 assets) external override {
        require(msg.sender == vault, "ONLY_VAULT");
        bool ok = asset.transfer(vault, assets);
        require(ok, "TF");
    }

    function totalUnderlying() external view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

contract Vault4626LikeTest is Test {
    MockERC20 asset;
    Vault4626Like vault;
    MockAdapter adapterA;
    MockAdapter adapterB;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address owner;

    function setUp() external {
        owner = address(this);

        asset = new MockERC20("MockAsset", "MA", 18);

        vault = new Vault4626Like(address(asset), "Vault Share", "vSHARE", 18);

        adapterA = new MockAdapter(address(asset), address(vault));
        adapterB = new MockAdapter(address(asset), address(vault));

        vault.setAdapters(address(adapterA), address(adapterB));

        // fund users
        asset.mint(alice, 1_000 ether);
        asset.mint(bob, 1_000 ether);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_deposit_bootstrap_1to1() external {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        assertEq(shares, 100 ether, "bootstrap shares should be 1:1");
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(asset.balanceOf(address(vault)), 100 ether);
    }

    function test_deposit_after_yield_mints_less_shares() external {
        // Alice deposits 100
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        // Owner allocates all to adapterA
        vault.allocate(0, 100 ether);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(adapterA)), 100 ether);

        // Simulate yield: mint 10 extra underlying directly to adapterA
        asset.mint(address(adapterA), 10 ether);

        // Total assets = 110
        assertEq(vault.totalAssets(), 110 ether);

        // Bob deposits 110 -> should mint 100 shares (since price/share increased)
        vm.prank(bob);
        uint256 shares = vault.deposit(110 ether, bob);

        assertEq(shares, 100 ether, "should mint fewer shares after yield");
        assertEq(vault.totalSupply(), 200 ether);
        assertEq(vault.totalAssets(), 220 ether);
    }

    function test_allocate_moves_idle_to_poolA() external {
        vm.prank(alice);
        vault.deposit(50 ether, alice);

        assertEq(asset.balanceOf(address(vault)), 50 ether);

        vault.allocate(0, 30 ether);

        assertEq(asset.balanceOf(address(vault)), 20 ether);
        assertEq(asset.balanceOf(address(adapterA)), 30 ether);
        assertEq(
            vault.totalAssets(),
            50 ether,
            "allocation shouldn't change totalAssets"
        );
    }

    function test_withdraw_pulls_from_adapters_in_order_A_then_B() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        // allocate: 60 to A, 40 to B, 0 idle
        vault.allocate(0, 60 ether);
        vault.allocate(1, 40 ether);
        assertEq(asset.balanceOf(address(vault)), 0);

        // withdraw 70 -> must pull 60 from A and 10 from B
        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(70 ether, alice, alice);

        assertEq(asset.balanceOf(alice), 1_000 ether - 100 ether + 70 ether);
        assertEq(asset.balanceOf(address(adapterA)), 0);
        assertEq(asset.balanceOf(address(adapterB)), 30 ether);
        assertEq(asset.balanceOf(address(vault)), 0);

        // shares burned should be ceil(70 * supply / totalAssets_before)
        // totalAssets_before was 100, supply was 100 => 70
        assertEq(sharesBurned, 70 ether);
        assertEq(vault.balanceOf(alice), 30 ether);
    }

    function test_redeem_uses_allowance_if_caller_not_owner() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(alice);
        vault.approve(bob, 25 ether);

        // allocate all so redeem must pull liquidity
        vault.allocate(0, 100 ether);

        vm.prank(bob);
        uint256 assetsOut = vault.redeem(25 ether, bob, alice);

        assertEq(assetsOut, 25 ether);
        assertEq(asset.balanceOf(bob), 1_000 ether + 25 ether);
        assertEq(vault.balanceOf(alice), 75 ether);
    }

    function test_rebalance_only_rebalancer() external {
        // Setup
        vault.setRebalancer(address(0xE3B));
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        vault.allocate(0, 100 ether);

        // Not rebalancer should fail
        vm.expectRevert("NOT_REBALANCER");
        vault.rebalance(0, 1, 50 ether);

        // Rebalancer moves 50 A -> B
        vm.prank(address(0xE3B));
        vault.rebalance(0, 1, 50 ether);

        assertEq(asset.balanceOf(address(adapterA)), 50 ether);
        assertEq(asset.balanceOf(address(adapterB)), 50 ether);
        assertEq(vault.totalAssets(), 100 ether);
    }

    function test_pause_blocks_user_and_rebalance_actions() external {
        vault.setRebalancer(address(0xE3B));
        vault.setPaused(true);

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        vault.deposit(1 ether, alice);

        vm.expectRevert("PAUSED");
        vault.allocate(0, 1 ether);

        vm.prank(address(0xE3B));
        vm.expectRevert("PAUSED");
        vault.rebalance(0, 1, 1 ether);

        // admin can unpause
        vault.setPaused(false);

        vm.prank(alice);
        vault.deposit(1 ether, alice);
        assertEq(vault.totalAssets(), 1 ether);
    }

    function test_only_owner_admin() external {
        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        vault.setPaused(true);

        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        vault.setAdapters(address(adapterA), address(adapterB));

        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        vault.setRebalancer(address(123));
    }
}
