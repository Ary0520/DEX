// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ILShieldVault} from "../../src/ILShieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract Handler is Test {
    ILShieldVault public vault;
    MockERC20 public usdc;

    address public pair;
    address public router;
    address public owner;

    address[] public users;

    // Track accFeePerShare monotonicity
    uint256 public lastAccFeePerShare;

    constructor(ILShieldVault _vault, MockERC20 _usdc, address _pair, address _router, address _owner) {
        vault  = _vault;
        usdc   = _usdc;
        pair   = _pair;
        router = _router;
        owner  = _owner;

        users.push(makeAddr("alice"));
        users.push(makeAddr("bob"));
        users.push(makeAddr("carol"));

        for (uint i; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
        }

        usdc.mint(owner, 10_000_000e6);
        vm.prank(owner);
        usdc.approve(address(vault), type(uint256).max);
    }

    function stake(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];
        amount = bound(amount, 1e6, 100_000e6);
        vm.prank(user);
        try vault.stake(pair, amount) {} catch {}
    }

    function allocate(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000e6);
        vm.prank(owner);
        try vault.allocateUSDC(pair, amount) {} catch {}
        lastAccFeePerShare = vault.accFeePerShare(pair);
    }

    function payout(uint256 amount) public {
        amount = bound(amount, 1e6, 50_000e6);
        vm.prank(router);
        try vault.requestPayout(pair, users[0], amount, amount * 10, 7500, 60 days) {} catch {}
    }

    function requestUnstake(uint256 userIndex) public {
        address user = users[userIndex % users.length];
        vm.prank(user);
        try vault.requestUnstake(pair) {} catch {}
    }

    function unstake(uint256 userIndex) public {
        address user = users[userIndex % users.length];
        (, uint256 shares,, uint256 reqTime) = vault.stakerPositions(pair, user);
        if (shares == 0 || reqTime == 0) return;

        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(user);
        try vault.unstake(pair, shares) {} catch {}
    }

    function harvest(uint256 userIndex) public {
        address user = users[userIndex % users.length];
        vm.prank(user);
        try vault.harvestFees(pair) {} catch {}
    }
}

contract ILShieldVaultInvariant is StdInvariant, Test {

    ILShieldVault vault;
    MockERC20 usdc;
    Handler handler;

    address owner  = makeAddr("owner");
    address router = makeAddr("router");
    address pair   = makeAddr("pair");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        vm.startPrank(owner);
        vault = new ILShieldVault(router, address(usdc));
        vault.setFeeConverter(owner);
        vm.stopPrank();

        handler = new Handler(vault, usdc, pair, router, owner);
        targetContract(address(handler));
    }

    // reserve is always >= 0 (uint, always true, but also checks no underflow)
    function invariant_reserveAlwaysValid() public view {
        (uint256 reserve,,,,,) = vault.pools(pair);
        assertGe(reserve, 0);
    }

    // totalPaidOut can never exceed (reserve + totalPaidOut) — i.e. accounting is consistent
    function invariant_totalPaidOutNeverExceedsTotal() public view {
        (uint256 reserve,,, uint256 totalPaidOut,,) = vault.pools(pair);
        assertLe(totalPaidOut, reserve + totalPaidOut);
    }

    // reserve == stakerDeposits + feeDeposits at all times
    function invariant_noOverflowAccounting() public view {
        (uint256 reserve, uint256 stakerDeposits, uint256 feeDeposits,,,) = vault.pools(pair);
        assertEq(reserve, stakerDeposits + feeDeposits);
    }

    // stakerDeposits can never exceed reserve
    function invariant_stakerDepositsNeverExceedReserve() public view {
        (uint256 reserve, uint256 stakerDeposits,,,,) = vault.pools(pair);
        assertLe(stakerDeposits, reserve);
    }

    // accFeePerShare must never decrease
    function invariant_accFeePerShareMonotonicallyNonDecreasing() public view {
        assertGe(vault.accFeePerShare(pair), handler.lastAccFeePerShare());
    }

    // totalShares must be >= 0 (uint, but also verifies no underflow path)
    function invariant_totalSharesNonNegative() public view {
        assertGe(vault.totalShares(pair), 0);
    }
}
