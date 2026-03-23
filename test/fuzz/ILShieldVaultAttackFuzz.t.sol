// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ILShieldVault} from "../../src/ILShieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ILShieldVaultAttackFuzz is Test {

    ILShieldVault vault;
    MockERC20 usdc;

    address owner  = makeAddr("owner");
    address router = makeAddr("router");
    address attacker = makeAddr("attacker");
    address victim   = makeAddr("victim");
    address pair     = makeAddr("pair");

    uint256 constant USDC_DEC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        vm.startPrank(owner);
        vault = new ILShieldVault(router, address(usdc));
        vault.setFeeConverter(owner);
        vm.stopPrank();

        usdc.mint(attacker, 1_000_000 * USDC_DEC);
        usdc.mint(victim,   1_000_000 * USDC_DEC);

        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(victim);
        usdc.approve(address(vault), type(uint256).max);

        usdc.mint(owner, 1_000_000 * USDC_DEC);
        vm.prank(owner);
        usdc.approve(address(vault), type(uint256).max);
    }

    // 💣 BANK RUN SIMULATION
    function testFuzz_bankRun(uint256 stakeAmt, uint256 payoutAmt) public {
        stakeAmt  = bound(stakeAmt, 10_000 * USDC_DEC, 200_000 * USDC_DEC);
        payoutAmt = bound(payoutAmt, 1_000 * USDC_DEC, 100_000 * USDC_DEC);

        vm.prank(attacker);
        vault.stake(pair, stakeAmt);

        vm.prank(owner);
        vault.allocateUSDC(pair, stakeAmt);

        vm.prank(router);
        vault.requestPayout(pair, victim, payoutAmt, payoutAmt * 10, 7500, 60 days);

        vm.prank(attacker);
        vault.requestUnstake(pair);

        vm.warp(block.timestamp + 14 days + 1);

        (, uint256 shares,,) = vault.stakerPositions(pair, attacker);

        vm.prank(attacker);
        vault.unstake(pair, shares);

        // attacker should NOT profit from system instability
        uint256 finalBal = usdc.balanceOf(attacker);

        // Must not exceed initial + total vault inflow
        assertLe(finalBal, 1_000_000 * USDC_DEC + 200_000 * USDC_DEC);
    }

    // 💣 SMALL DRAIN ATTACK
    function testFuzz_repeatedSmallPayoutDrain(uint256 amount) public {
        amount = bound(amount, 1_000 * USDC_DEC, 10_000 * USDC_DEC);

        vm.prank(owner);
        vault.allocateUSDC(pair, 200_000 * USDC_DEC);

        for (uint i; i < 10; i++) {
            vm.prank(router);
            vault.requestPayout(pair, attacker, amount, amount * 10, 7500, 60 days);
        }

        (uint256 reserve,,,,,) = vault.pools(pair);

        assertGt(reserve, 0); // vault should not fully drain
    }

    // 💣 REWARD EXTRACTION ATTACK
    function testFuzz_rewardExtraction(uint256 stakeAmt) public {
        stakeAmt = bound(stakeAmt, 1_000 * USDC_DEC, 100_000 * USDC_DEC);

        vm.prank(attacker);
        vault.stake(pair, stakeAmt);

        vm.prank(owner);
        vault.allocateUSDC(pair, 50_000 * USDC_DEC);

        uint256 before = usdc.balanceOf(attacker);

        vm.prank(attacker);
        vault.harvestFees(pair);

        uint256 afterBal = usdc.balanceOf(attacker);

        assertLe(afterBal - before, 50_000 * USDC_DEC);
    }

    // 💣 STAKER DILUTION ATTACK
    function testFuzz_stakerDilution(uint256 a, uint256 b) public {
        a = bound(a, 1_000 * USDC_DEC, 100_000 * USDC_DEC);
        b = bound(b, 1_000 * USDC_DEC, 100_000 * USDC_DEC);

        vm.prank(attacker);
        vault.stake(pair, a);

        vm.prank(victim);
        vault.stake(pair, b);

        (, uint256 sharesA,,) = vault.stakerPositions(pair, attacker);
        (, uint256 sharesB,,) = vault.stakerPositions(pair, victim);

        uint256 totalShares = vault.totalShares(pair);

        assertEq(sharesA + sharesB, totalShares);
    }
}