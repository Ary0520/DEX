// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ILShieldVault} from "../../src/ILShieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ILShieldVaultFuzz is Test {

    ILShieldVault vault;
    MockERC20 usdc;

    address owner  = makeAddr("owner");
    address router = makeAddr("router");
    address alice  = makeAddr("alice");
    address pair   = makeAddr("pair");

    uint256 constant USDC_DEC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        vm.startPrank(owner);
        vault = new ILShieldVault(router, address(usdc));
        vault.setFeeConverter(owner);
        vm.stopPrank();

        usdc.mint(alice, 1_000_000 * USDC_DEC);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        usdc.mint(owner, 1_000_000 * USDC_DEC);
        vm.prank(owner);
        usdc.approve(address(vault), type(uint256).max);
    }

    function testFuzz_stake_unstake_symmetry(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000 * USDC_DEC);

        vm.prank(alice);
        vault.stake(pair, amount);

        vm.prank(alice);
        vault.requestUnstake(pair);

        vm.warp(block.timestamp + 14 days + 1);

        (, uint256 shares,,) = vault.stakerPositions(pair, alice);

        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.unstake(pair, shares);

        uint256 afterBal = usdc.balanceOf(alice);

        assertApproxEqAbs(afterBal, before + amount, 2);
    }

    function testFuzz_payout_neverExceedsReserve(
        uint256 seed,
        uint256 il
    ) public {
        seed = bound(seed, 1000 * USDC_DEC, 1_000_000 * USDC_DEC);
        il   = bound(il,   1e6,              100_000 * USDC_DEC);

        vm.prank(owner);
        vault.allocateUSDC(pair, seed);

        (uint256 reserveBefore,,,,,) = vault.pools(pair);

        vm.prank(router);
        uint256 payout = vault.requestPayout(
            pair,
            alice,
            il,
            il * 10,
            7500,
            60 days
        );

        assertLe(payout, reserveBefore);
    }

    function testFuzz_reserveAccounting(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000 * USDC_DEC);

        vm.prank(owner);
        vault.allocateUSDC(pair, amount);

        (
            uint256 reserve,
            uint256 stakerDeposits,
            uint256 feeDeposits,
            ,
            ,
        ) = vault.pools(pair);

        assertEq(reserve, stakerDeposits + feeDeposits);
    }
}