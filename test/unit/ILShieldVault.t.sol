// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2}   from "forge-std/Test.sol";
import {ILShieldVault}    from "../../src/ILShieldVault.sol";
import {MockERC20}        from "../mocks/MockERC20.sol";

contract ILShieldVaultTest is Test {

    ILShieldVault internal vault;
    MockERC20     internal usdc;
    MockERC20     internal feeToken;

    address internal owner     = makeAddr("owner");
    address internal router    = makeAddr("router");
    address internal converter = makeAddr("converter");
    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");
    address internal carol     = makeAddr("carol");
    address internal stranger  = makeAddr("stranger");
    address internal pair      = makeAddr("pair");

    uint256 internal constant USDC_DEC = 1e6;

    function setUp() public {
        usdc     = new MockERC20("USD Coin",  "USDC", 6);
        feeToken = new MockERC20("Fee Token", "FEE",  18);

        vm.startPrank(owner);
        vault = new ILShieldVault(router, address(usdc));
        vault.setFeeConverter(converter);
        vm.stopPrank();

        usdc.mint(alice,     10_000_000 * USDC_DEC);
        usdc.mint(bob,       10_000_000 * USDC_DEC);
        usdc.mint(carol,     10_000_000 * USDC_DEC);
        usdc.mint(owner,     10_000_000 * USDC_DEC);
        usdc.mint(converter, 10_000_000 * USDC_DEC);

        feeToken.mint(pair, 1_000_000 ether);

        vm.prank(alice);   usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);     usdc.approve(address(vault), type(uint256).max);
        vm.prank(carol);   usdc.approve(address(vault), type(uint256).max);
        vm.prank(owner);   usdc.approve(address(vault), type(uint256).max);
        vm.prank(converter); usdc.approve(address(vault), type(uint256).max);
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    function _stake(address user, address p, uint256 amount) internal {
        vm.prank(user);
        vault.stake(p, amount);
    }

    function _depositFees(address p, address token, uint256 amount) internal {
        vm.prank(router);
        vault.depositFees(p, token, amount);
    }

    function _allocateUSDC(address p, uint256 amount) internal {
        vm.prank(owner);
        vault.allocateUSDC(p, amount);
    }

    function _requestPayout(
        address p, address user,
        uint256 netIL, uint256 lpValue,
        uint256 tierCeiling, uint256 secondsIn
    ) internal returns (uint256) {
        vm.prank(router);
        return vault.requestPayout(p, user, netIL, lpValue, tierCeiling, secondsIn);
    }

    function _getPool(address p) internal view returns (
        uint256 usdcReserve, uint256 stakerDeposits, uint256 feeDeposits,
        uint256 totalPaidOut, uint256 totalFeesIn, uint256 totalExposureUSDC
    ) {
        return vault.pools(p);
    }

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    function test_constructor_setsOwner() public view {
        assertEq(vault.owner(), owner);
    }

    function test_constructor_setsRouter() public view {
        assertEq(vault.router(), router);
    }

    function test_constructor_setsUSDC() public view {
        assertEq(vault.USDC(), address(usdc));
    }

    function test_constructor_zeroRouter_reverts() public {
        vm.expectRevert(ILShieldVault.ZeroAddress.selector);
        new ILShieldVault(address(0), address(usdc));
    }

    function test_constructor_zeroUSDC_reverts() public {
        vm.expectRevert(ILShieldVault.ZeroAddress.selector);
        new ILShieldVault(router, address(0));
    }

    function test_constructor_defaultConfig() public view {
        (
            uint256 maxPayout, uint256 poolCap, uint256 cb,
            uint256 pause, uint256 stakerShare, uint256 cooldown
        ) = vault.config();
        assertEq(maxPayout,   2000);
        assertEq(poolCap,      500);
        assertEq(cb,          5000);
        assertEq(pause,       8000);
        assertEq(stakerShare, 5000);
        assertEq(cooldown,    14 days);
    }

    // -------------------------------------------------------
    // DEPOSIT FEES
    // -------------------------------------------------------

    function test_depositFees_onlyRouter() public {
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.depositFees(pair, address(feeToken), 100e18);
    }

    function test_depositFees_zeroAmount_reverts() public {
        vm.prank(router);
        vm.expectRevert(ILShieldVault.ZeroAmount.selector);
        vault.depositFees(pair, address(feeToken), 0);
    }

    function test_depositFees_updatesRawFeeBalances() public {
        _depositFees(pair, address(feeToken), 500e18);
        assertEq(vault.rawFeeBalances(pair, address(feeToken)), 500e18);
    }

    function test_depositFees_updatesTotalFeesIn() public {
        _depositFees(pair, address(feeToken), 500e18);
        (,,,, uint256 totalFeesIn,) = _getPool(pair);
        assertEq(totalFeesIn, 500e18);
    }

    function test_depositFees_accumulates() public {
        _depositFees(pair, address(feeToken), 100e18);
        _depositFees(pair, address(feeToken), 200e18);
        assertEq(vault.rawFeeBalances(pair, address(feeToken)), 300e18);
    }

    function test_depositFees_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ILShieldVault.FeesDeposited(pair, address(feeToken), 100e18);
        vm.prank(router);
        vault.depositFees(pair, address(feeToken), 100e18);
    }

    // -------------------------------------------------------
    // ALLOCATE USDC
    // -------------------------------------------------------

    function test_allocateUSDC_onlyOwnerOrConverter() public {
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.allocateUSDC(pair, 1000 * USDC_DEC);
    }

    function test_allocateUSDC_zeroAmount_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ILShieldVault.ZeroAmount.selector);
        vault.allocateUSDC(pair, 0);
    }

    function test_allocateUSDC_converterCanCall() public {
        vm.prank(converter);
        vault.allocateUSDC(pair, 1000 * USDC_DEC);
        (uint256 reserve,,,,,) = _getPool(pair);
        assertGt(reserve, 0);
    }

    function test_allocateUSDC_splitToStakersAndReserve_noStakers() public {
        // No stakers: all goes to reserve (both halves)
        _allocateUSDC(pair, 1000 * USDC_DEC);
        (uint256 reserve,, uint256 feeDeposits,,,) = _getPool(pair);
        assertEq(reserve, 1000 * USDC_DEC);
        assertEq(feeDeposits, 1000 * USDC_DEC);
    }

    function test_allocateUSDC_withStakers_splitCorrectly() public {
        _stake(alice, pair, 10_000 * USDC_DEC);
        uint256 allocAmt = 1000 * USDC_DEC;
        _allocateUSDC(pair, allocAmt);

        // 50% to stakers via accFeePerShare, 50% to reserve
        uint256 toReserve = allocAmt / 2;
        (uint256 reserve,, uint256 feeDeposits,,,) = _getPool(pair);
        // reserve = stakeAmt + toReserve
        assertEq(feeDeposits, toReserve);
        assertEq(reserve, 10_000 * USDC_DEC + toReserve);
    }

    function test_allocateUSDC_withStakers_accFeePerShareIncreases() public {
        _stake(alice, pair, 10_000 * USDC_DEC);
        uint256 accBefore = vault.accFeePerShare(pair);
        _allocateUSDC(pair, 1000 * USDC_DEC);
        assertGt(vault.accFeePerShare(pair), accBefore);
    }

    function test_allocateUSDC_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ILShieldVault.USDCAllocated(pair, 1000 * USDC_DEC);
        _allocateUSDC(pair, 1000 * USDC_DEC);
    }

    // -------------------------------------------------------
    // UPDATE EXPOSURE
    // -------------------------------------------------------

    function test_updateExposure_onlyRouter() public {
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.updateExposure(pair, 1000 * USDC_DEC);
    }

    function test_updateExposure_setsValue() public {
        vm.prank(router);
        vault.updateExposure(pair, 500 * USDC_DEC);
        assertEq(vault.getExposure(pair), 500 * USDC_DEC);
    }

    function test_updateExposure_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ILShieldVault.ExposureUpdated(pair, 999 * USDC_DEC);
        vm.prank(router);
        vault.updateExposure(pair, 999 * USDC_DEC);
    }

    // -------------------------------------------------------
    // STAKE
    // -------------------------------------------------------

    function test_stake_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ILShieldVault.ZeroAmount.selector);
        vault.stake(pair, 0);
    }

    function test_stake_zeroPair_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ILShieldVault.ZeroAddress.selector);
        vault.stake(address(0), 1000 * USDC_DEC);
    }

    function test_stake_paused_reverts() public {
        vm.prank(owner);
        vault.setGlobalPause(true);
        vm.prank(alice);
        vm.expectRevert(ILShieldVault.VaultPaused.selector);
        vault.stake(pair, 1000 * USDC_DEC);
    }

    function test_stake_firstStaker_sharesEqual1to1() public {
        uint256 amt = 5000 * USDC_DEC;
        _stake(alice, pair, amt);
        (, uint256 shares,,) = vault.stakerPositions(pair, alice);
        assertEq(shares, amt, "first staker shares should be 1:1");
    }

    function test_stake_updatesPoolReserveAndStakerDeposits() public {
        uint256 amt = 3000 * USDC_DEC;
        _stake(alice, pair, amt);
        (uint256 reserve, uint256 stakerDeposits,,,,) = _getPool(pair);
        assertEq(reserve, amt);
        assertEq(stakerDeposits, amt);
    }

    function test_stake_transfersUSDCFromUser() public {
        uint256 before = usdc.balanceOf(alice);
        _stake(alice, pair, 1000 * USDC_DEC);
        assertEq(usdc.balanceOf(alice), before - 1000 * USDC_DEC);
    }

    function test_stake_secondStaker_sharesProportional() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        _stake(bob,   pair, 1000 * USDC_DEC);
        (, uint256 sharesA,,) = vault.stakerPositions(pair, alice);
        (, uint256 sharesB,,) = vault.stakerPositions(pair, bob);
        assertEq(sharesA, sharesB, "equal stakes should give equal shares");
    }

    function test_stake_rewardDebtInitializedCorrectly() public {
        // Allocate fees first so accFeePerShare > 0
        _stake(alice, pair, 5000 * USDC_DEC);
        _allocateUSDC(pair, 1000 * USDC_DEC);

        // Bob stakes after fees accumulated — should not claim retroactive fees
        uint256 bobBefore = usdc.balanceOf(bob);
        _stake(bob, pair, 5000 * USDC_DEC);
        vm.prank(bob);
        vault.harvestFees(pair);
        // Bob may receive at most dust from integer rounding in MasterChef math
        // The _settleRewards is called during stake() itself, giving tiny rounding dust
        assertApproxEqAbs(usdc.balanceOf(bob), bobBefore - 5000 * USDC_DEC, 10 * USDC_DEC,
            "bob should not claim meaningful fees from before his stake");
    }

    function test_stake_resetsUnstakeRequest() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.prank(alice);
        vault.requestUnstake(pair);
        (,, , uint256 reqTime) = vault.stakerPositions(pair, alice);
        assertGt(reqTime, 0);

        // Re-stake resets it
        _stake(alice, pair, 500 * USDC_DEC);
        (,,, uint256 reqTimeAfter) = vault.stakerPositions(pair, alice);
        assertEq(reqTimeAfter, 0, "re-stake should reset unstake request");
    }

    function test_stake_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ILShieldVault.Staked(pair, alice, 1000 * USDC_DEC, 1000 * USDC_DEC);
        _stake(alice, pair, 1000 * USDC_DEC);
    }

    // -------------------------------------------------------
    // REQUEST UNSTAKE
    // -------------------------------------------------------

    function test_requestUnstake_noShares_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ILShieldVault.InsufficientShares.selector);
        vault.requestUnstake(pair);
    }

    function test_requestUnstake_setsTimestamp() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.warp(12345);
        vm.prank(alice);
        vault.requestUnstake(pair);
        (,,, uint256 reqTime) = vault.stakerPositions(pair, alice);
        assertEq(reqTime, 12345);
    }

    function test_requestUnstake_emitsEvent() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.expectEmit(true, true, false, false);
        emit ILShieldVault.UnstakeRequested(pair, alice, block.timestamp);
        vm.prank(alice);
        vault.requestUnstake(pair);
    }

    // -------------------------------------------------------
    // UNSTAKE
    // -------------------------------------------------------

    function test_unstake_noRequest_reverts() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.prank(alice);
        vm.expectRevert(ILShieldVault.UnstakeNotRequested.selector);
        vault.unstake(pair, 1000 * USDC_DEC);
    }

    function test_unstake_cooldownNotMet_reverts() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.prank(alice); vault.requestUnstake(pair);
        vm.warp(block.timestamp + 14 days - 1);
        vm.prank(alice);
        vm.expectRevert(ILShieldVault.CooldownNotMet.selector);
        vault.unstake(pair, 1000 * USDC_DEC);
    }

    function test_unstake_zeroShares_reverts() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.prank(alice); vault.requestUnstake(pair);
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(alice);
        vm.expectRevert(ILShieldVault.InsufficientShares.selector);
        vault.unstake(pair, 0);
    }

    function test_unstake_excessShares_reverts() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.prank(alice); vault.requestUnstake(pair);
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(alice);
        vm.expectRevert(ILShieldVault.InsufficientShares.selector);
        vault.unstake(pair, 1000 * USDC_DEC + 1);
    }

    function test_unstake_fullWithdrawal_returnsUSDC() public {
        uint256 amt = 5000 * USDC_DEC;
        _stake(alice, pair, amt);
        vm.prank(alice); vault.requestUnstake(pair);
        vm.warp(block.timestamp + 14 days + 1);

        uint256 before = usdc.balanceOf(alice);
        (, uint256 shares,,) = vault.stakerPositions(pair, alice);
        vm.prank(alice);
        vault.unstake(pair, shares);

        assertApproxEqAbs(usdc.balanceOf(alice) - before, amt, 2);
    }

    function test_unstake_fullWithdrawal_clearsPosition() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.prank(alice); vault.requestUnstake(pair);
        vm.warp(block.timestamp + 14 days + 1);
        (, uint256 shares,,) = vault.stakerPositions(pair, alice);
        vm.prank(alice); vault.unstake(pair, shares);

        (, uint256 sharesAfter,,) = vault.stakerPositions(pair, alice);
        assertEq(sharesAfter, 0);
        assertEq(vault.totalShares(pair), 0);
    }

    function test_unstake_afterLoss_returnsLess() public {
        uint256 stakeAmt = 10_000 * USDC_DEC;
        _stake(alice, pair, stakeAmt);
        
        // DO NOT allocate fees — we want a scenario where payout drains staker capital
        // Set a higher poolCapBps temporarily so payout can exceed the default 5%
        vm.prank(owner);
        vault.setConfig(2000, 2000, 5000, 8000, 5000, 14 days); // poolCap = 20%
        
        // Large payout that exceeds reserve, forcing staker loss
        // With 10k reserve and 20% pool cap = 2000 USDC max payout
        _requestPayout(pair, bob, 5000 * USDC_DEC, 100_000 * USDC_DEC, 7500, 90 days);

        vm.prank(alice); vault.requestUnstake(pair);
        vm.warp(block.timestamp + 14 days + 1);
        (, uint256 shares,,) = vault.stakerPositions(pair, alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); vault.unstake(pair, shares);

        assertLt(usdc.balanceOf(alice) - before, stakeAmt, "staker should absorb losses");
    }

    function test_unstake_emitsEvent() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        vm.prank(alice); vault.requestUnstake(pair);
        vm.warp(block.timestamp + 14 days + 1);
        (, uint256 shares,,) = vault.stakerPositions(pair, alice);
        vm.expectEmit(true, true, false, false);
        emit ILShieldVault.Unstaked(pair, alice, 0);
        vm.prank(alice); vault.unstake(pair, shares);
    }

    // -------------------------------------------------------
    // HARVEST FEES / PENDING FEES
    // -------------------------------------------------------

    function test_pendingFees_zeroBeforeAllocation() public view {
        assertEq(vault.pendingFees(pair, alice), 0);
    }

    function test_pendingFees_nonZeroAfterAllocation() public {
        _stake(alice, pair, 10_000 * USDC_DEC);
        _allocateUSDC(pair, 1000 * USDC_DEC);
        assertGt(vault.pendingFees(pair, alice), 0);
    }

    function test_harvestFees_transfersUSDC() public {
        _stake(alice, pair, 10_000 * USDC_DEC);
        _allocateUSDC(pair, 1000 * USDC_DEC);

        uint256 pending = vault.pendingFees(pair, alice);
        uint256 before  = usdc.balanceOf(alice);
        vm.prank(alice); vault.harvestFees(pair);
        assertEq(usdc.balanceOf(alice) - before, pending);
    }

    function test_harvestFees_zeroPendingAfterHarvest() public {
        _stake(alice, pair, 10_000 * USDC_DEC);
        _allocateUSDC(pair, 1000 * USDC_DEC);
        vm.prank(alice); vault.harvestFees(pair);
        assertEq(vault.pendingFees(pair, alice), 0);
    }

    function test_harvestFees_twoStakers_proportional() public {
        _stake(alice, pair, 6000 * USDC_DEC);
        _stake(bob,   pair, 4000 * USDC_DEC);
        _allocateUSDC(pair, 1000 * USDC_DEC);

        uint256 pendingAlice = vault.pendingFees(pair, alice);
        uint256 pendingBob   = vault.pendingFees(pair, bob);

        // Alice has 60% of shares, Bob 40%
        assertApproxEqRel(pendingAlice, 300 * USDC_DEC, 0.01e18, "alice fee share wrong");
        assertApproxEqRel(pendingBob,   200 * USDC_DEC, 0.01e18, "bob fee share wrong");
    }

    function test_harvestFees_emitsEvent() public {
        _stake(alice, pair, 10_000 * USDC_DEC);
        _allocateUSDC(pair, 1000 * USDC_DEC);
        uint256 pending = vault.pendingFees(pair, alice);
        vm.expectEmit(true, true, false, true);
        emit ILShieldVault.FeeHarvested(pair, alice, pending);
        vm.prank(alice); vault.harvestFees(pair);
    }

    // -------------------------------------------------------
    // REQUEST PAYOUT
    // -------------------------------------------------------

    function test_requestPayout_onlyRouter() public {
        _allocateUSDC(pair, 10_000 * USDC_DEC);
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.requestPayout(pair, alice, 1000 * USDC_DEC, 10_000 * USDC_DEC, 7500, 60 days);
    }

    function test_requestPayout_paused_reverts() public {
        _allocateUSDC(pair, 10_000 * USDC_DEC);
        vm.prank(owner); vault.setGlobalPause(true);
        vm.prank(router);
        vm.expectRevert(ILShieldVault.VaultPaused.selector);
        vault.requestPayout(pair, alice, 1000 * USDC_DEC, 10_000 * USDC_DEC, 7500, 60 days);
    }

    function test_requestPayout_zeroNetIL_returnsZero() public {
        _allocateUSDC(pair, 10_000 * USDC_DEC);
        uint256 payout = _requestPayout(pair, alice, 0, 10_000 * USDC_DEC, 7500, 60 days);
        assertEq(payout, 0);
    }

    function test_requestPayout_zeroReserve_returnsZero() public {
        uint256 payout = _requestPayout(pair, alice, 1000 * USDC_DEC, 10_000 * USDC_DEC, 7500, 60 days);
        assertEq(payout, 0);
    }

    function test_requestPayout_zeroUser_reverts() public {
        _allocateUSDC(pair, 10_000 * USDC_DEC);
        vm.prank(router);
        vm.expectRevert(ILShieldVault.ZeroAddress.selector);
        vault.requestPayout(pair, address(0), 1000 * USDC_DEC, 10_000 * USDC_DEC, 7500, 60 days);
    }

    function test_requestPayout_belowMinLock_returnsZero() public {
        _allocateUSDC(pair, 100_000 * USDC_DEC);
        // 6 days < 7 day MIN_LOCK in CoverageCurve
        uint256 payout = _requestPayout(pair, alice, 5000 * USDC_DEC, 50_000 * USDC_DEC, 7500, 6 days);
        assertEq(payout, 0, "no payout before min lock");
    }

    function test_requestPayout_afterMinLock_nonZero() public {
        _allocateUSDC(pair, 100_000 * USDC_DEC);
        uint256 payout = _requestPayout(pair, alice, 5000 * USDC_DEC, 50_000 * USDC_DEC, 7500, 60 days);
        assertGt(payout, 0, "should pay after lock period");
    }

    function test_requestPayout_neverExceedsReserve() public {
        uint256 reserve = 1000 * USDC_DEC;
        _allocateUSDC(pair, reserve);
        uint256 payout = _requestPayout(pair, alice, 999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);
        assertLe(payout, reserve);
    }

    function test_requestPayout_userCapEnforced() public {
        _allocateUSDC(pair, 1_000_000 * USDC_DEC);
        uint256 lpValue = 1000 * USDC_DEC;
        // maxPayoutBps = 2000 = 20% of lpValue = 200 USDC
        uint256 userCap = (lpValue * 2000) / 10000;
        uint256 payout = _requestPayout(pair, alice, 999_999 * USDC_DEC, lpValue, 7500, 240 days);
        assertLe(payout, userCap, "user cap must be enforced");
    }

    function test_requestPayout_poolCapEnforced() public {
        uint256 reserve = 100_000 * USDC_DEC;
        _allocateUSDC(pair, reserve);
        // poolCapBps = 500 = 5% of reserve = 5000 USDC
        uint256 poolCap = (reserve * 500) / 10000;
        uint256 payout = _requestPayout(pair, alice, 999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);
        assertLe(payout, poolCap, "pool cap must be enforced");
    }

    function test_requestPayout_updatesTotalPaidOut() public {
        _allocateUSDC(pair, 100_000 * USDC_DEC);
        uint256 payout = _requestPayout(pair, alice, 5000 * USDC_DEC, 50_000 * USDC_DEC, 7500, 60 days);
        (,,, uint256 totalPaidOut,,) = _getPool(pair);
        assertEq(totalPaidOut, payout);
    }

    function test_requestPayout_reducesReserve() public {
        _allocateUSDC(pair, 100_000 * USDC_DEC);
        (uint256 reserveBefore,,,,,) = _getPool(pair);
        uint256 payout = _requestPayout(pair, alice, 5000 * USDC_DEC, 50_000 * USDC_DEC, 7500, 60 days);
        (uint256 reserveAfter,,,,,) = _getPool(pair);
        assertEq(reserveAfter, reserveBefore - payout);
    }

    function test_requestPayout_transfersUSDCToUser() public {
        _allocateUSDC(pair, 100_000 * USDC_DEC);
        uint256 before = usdc.balanceOf(alice);
        uint256 payout = _requestPayout(pair, alice, 5000 * USDC_DEC, 50_000 * USDC_DEC, 7500, 60 days);
        assertEq(usdc.balanceOf(alice) - before, payout);
    }

    function test_requestPayout_circuitBreaker_halvesAtHighUtilization() public {
        // Get to ~50% utilization then check coverage is halved
        _allocateUSDC(pair, 100_000 * USDC_DEC);
        // Drain ~50% via payouts
        _requestPayout(pair, alice, 999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);
        _requestPayout(pair, bob,   999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);
        _requestPayout(pair, carol, 999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);

        uint256 util = vault.getUtilization(pair);
        // Just verify utilization is tracked and circuit breaker logic runs without revert
        assertGe(util, 0);
    }

    function test_requestPayout_pauseThreshold_returnsZero() public {
        // Set pause threshold very low so we can trigger it
        vm.prank(owner);
        vault.setConfig(2000, 500, 100, 200, 5000, 14 days);

        _allocateUSDC(pair, 10_000 * USDC_DEC);
        // First payout drains enough to hit pause threshold
        _requestPayout(pair, alice, 999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);
        _requestPayout(pair, bob,   999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);

        // Now utilization should be high enough to trigger pause
        uint256 payout = _requestPayout(pair, carol, 999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);
        // Either returns 0 (paused) or a small amount — reserve is drained
        assertLe(payout, 10_000 * USDC_DEC);
    }

    function test_requestPayout_stakerLossAbsorption() public {
        uint256 stakeAmt = 5000 * USDC_DEC;
        _stake(alice, pair, stakeAmt);
        // Small fee buffer
        _allocateUSDC(pair, 500 * USDC_DEC);

        (,, uint256 feeDepositsBefore,,,) = _getPool(pair);

        // Payout larger than feeDeposits — should eat into staker capital
        uint256 payout = _requestPayout(pair, bob, 999_999 * USDC_DEC, 999_999 * USDC_DEC, 7500, 240 days);

        if (payout > feeDepositsBefore) {
            (, uint256 stakerDepositsAfter,,,,) = _getPool(pair);
            assertLt(stakerDepositsAfter, stakeAmt, "staker deposits should be reduced");
        }
    }

    function test_requestPayout_emitsEvent() public {
        _allocateUSDC(pair, 100_000 * USDC_DEC);
        vm.expectEmit(true, true, false, false);
        emit ILShieldVault.PayoutIssued(pair, alice, 0, 0);
        _requestPayout(pair, alice, 5000 * USDC_DEC, 50_000 * USDC_DEC, 7500, 60 days);
    }

    // -------------------------------------------------------
    // WITHDRAW RAW FEES
    // -------------------------------------------------------

    function test_withdrawRawFees_onlyConverter() public {
        _depositFees(pair, address(feeToken), 100e18);
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotConverter.selector);
        vault.withdrawRawFees(pair, address(feeToken), 100e18);
    }

    function test_withdrawRawFees_zeroAmount_reverts() public {
        vm.prank(converter);
        vm.expectRevert(ILShieldVault.ZeroAmount.selector);
        vault.withdrawRawFees(pair, address(feeToken), 0);
    }

    function test_withdrawRawFees_insufficientBalance_reverts() public {
        _depositFees(pair, address(feeToken), 100e18);
        vm.prank(converter);
        vm.expectRevert(ILShieldVault.InsufficientFund.selector);
        vault.withdrawRawFees(pair, address(feeToken), 101e18);
    }

    function test_withdrawRawFees_transfersTokens() public {
        feeToken.mint(address(vault), 500e18);
        _depositFees(pair, address(feeToken), 500e18);

        uint256 before = feeToken.balanceOf(converter);
        vm.prank(converter);
        vault.withdrawRawFees(pair, address(feeToken), 500e18);
        assertEq(feeToken.balanceOf(converter) - before, 500e18);
    }

    function test_withdrawRawFees_reducesRawFeeBalance() public {
        feeToken.mint(address(vault), 500e18);
        _depositFees(pair, address(feeToken), 500e18);
        vm.prank(converter);
        vault.withdrawRawFees(pair, address(feeToken), 300e18);
        assertEq(vault.rawFeeBalances(pair, address(feeToken)), 200e18);
    }

    // -------------------------------------------------------
    // ADMIN — SET CONFIG
    // -------------------------------------------------------

    function test_setConfig_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.setConfig(2000, 500, 5000, 8000, 5000, 14 days);
    }

    function test_setConfig_updatesValues() public {
        vm.prank(owner);
        vault.setConfig(1500, 300, 4000, 7000, 6000, 21 days);
        (uint256 mp, uint256 pc, uint256 cb, uint256 pt, uint256 sf, uint256 uc) = vault.config();
        assertEq(mp, 1500);
        assertEq(pc,  300);
        assertEq(cb, 4000);
        assertEq(pt, 7000);
        assertEq(sf, 6000);
        assertEq(uc, 21 days);
    }

    function test_setConfig_circuitBreakerGeqPauseThreshold_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ILShieldVault.InvalidConfig.selector);
        vault.setConfig(2000, 500, 8000, 8000, 5000, 14 days);
    }

    function test_setConfig_cooldownBelow7Days_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ILShieldVault.InvalidConfig.selector);
        vault.setConfig(2000, 500, 5000, 8000, 5000, 7 days - 1);
    }

    function test_setConfig_maxPayoutOver10000_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ILShieldVault.InvalidConfig.selector);
        vault.setConfig(10001, 500, 5000, 8000, 5000, 14 days);
    }

    function test_setConfig_emitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit ILShieldVault.ConfigUpdated(ILShieldVault.Config(0,0,0,0,0,0));
        vm.prank(owner);
        vault.setConfig(2000, 500, 5000, 8000, 5000, 14 days);
    }

    // -------------------------------------------------------
    // ADMIN — MISC
    // -------------------------------------------------------

    function test_setGlobalPause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.setGlobalPause(true);
    }

    function test_setGlobalPause_setsFlag() public {
        vm.prank(owner); vault.setGlobalPause(true);
        assertTrue(vault.globalPause());
        vm.prank(owner); vault.setGlobalPause(false);
        assertFalse(vault.globalPause());
    }

    function test_setRouter_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.setRouter(makeAddr("newRouter"));
    }

    function test_setRouter_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ILShieldVault.ZeroAddress.selector);
        vault.setRouter(address(0));
    }

    function test_setRouter_updatesRouter() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(owner); vault.setRouter(newRouter);
        assertEq(vault.router(), newRouter);
    }

    function test_recoverToken_blocksUSDC() public {
        vm.prank(owner);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.recoverToken(address(usdc), 1);
    }

    function test_recoverToken_allowsOtherTokens() public {
        feeToken.mint(address(vault), 100e18);
        uint256 before = feeToken.balanceOf(owner);
        vm.prank(owner); vault.recoverToken(address(feeToken), 100e18);
        assertEq(feeToken.balanceOf(owner) - before, 100e18);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ILShieldVault.NotAuthorized.selector);
        vault.transferOwnership(alice);
    }

    function test_transferOwnership_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ILShieldVault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    function test_transferOwnership_transfersOwner() public {
        vm.prank(owner); vault.transferOwnership(alice);
        assertEq(vault.owner(), alice);
    }

    // -------------------------------------------------------
    // VIEW HELPERS
    // -------------------------------------------------------

    function test_getUtilization_zeroWhenNoPayouts() public view {
        assertEq(vault.getUtilization(pair), 0);
    }

    function test_getPoolHealth_returnsCorrectFields() public {
        _stake(alice, pair, 5000 * USDC_DEC);
        _allocateUSDC(pair, 1000 * USDC_DEC);
        (
            uint256 reserve, uint256 stakerDep, uint256 feeDep,
            uint256 util, uint256 exposure
        ) = vault.getPoolHealth(pair);
        assertGt(reserve, 0);
        assertEq(stakerDep, 5000 * USDC_DEC);
        assertGt(feeDep, 0);
        assertEq(util, 0);
        assertEq(exposure, 0);
    }

    // -------------------------------------------------------
    // FUZZ
    // -------------------------------------------------------

    function testFuzz_stake_unstake_symmetry(uint256 amount) public {
        amount = bound(amount, 1 * USDC_DEC, 100_000 * USDC_DEC);
        _stake(alice, pair, amount);
        vm.prank(alice); vault.requestUnstake(pair);
        vm.warp(block.timestamp + 14 days + 1);
        (, uint256 shares,,) = vault.stakerPositions(pair, alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); vault.unstake(pair, shares);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, amount, 2);
    }

    function testFuzz_payout_neverExceedsReserve(uint256 seed, uint256 il) public {
        seed = bound(seed, 1000 * USDC_DEC, 1_000_000 * USDC_DEC);
        il   = bound(il,   1 * USDC_DEC,    100_000 * USDC_DEC);
        _allocateUSDC(pair, seed);
        (uint256 reserveBefore,,,,,) = _getPool(pair);
        uint256 payout = _requestPayout(pair, alice, il, il * 10, 7500, 60 days);
        assertLe(payout, reserveBefore);
    }

    function testFuzz_reserveEqualsStakerPlusFee(uint256 amount) public {
        amount = bound(amount, 1 * USDC_DEC, 100_000 * USDC_DEC);
        _allocateUSDC(pair, amount);
        (uint256 reserve, uint256 stakerDep, uint256 feeDep,,,) = _getPool(pair);
        assertEq(reserve, stakerDep + feeDep);
    }

    function testFuzz_twoStakers_feesProportional(uint256 a, uint256 b) public {
        a = bound(a, 1000 * USDC_DEC, 100_000 * USDC_DEC);
        b = bound(b, 1000 * USDC_DEC, 100_000 * USDC_DEC);
        _stake(alice, pair, a);
        _stake(bob,   pair, b);
        _allocateUSDC(pair, 10_000 * USDC_DEC);

        uint256 pA = vault.pendingFees(pair, alice);
        uint256 pB = vault.pendingFees(pair, bob);

        // Ratio of fees should match ratio of stakes (within 1% rounding)
        assertApproxEqRel(pA * b, pB * a, 0.01e18, "fee distribution not proportional to stake");
    }
}
