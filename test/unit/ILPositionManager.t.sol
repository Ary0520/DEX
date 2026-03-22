// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2}      from "forge-std/Test.sol";
import {ILPositionManager}   from "../../src/ILPositionManager.sol";

contract ILPositionManagerTest is Test {

    ILPositionManager internal pm;

    address internal router  = makeAddr("router");
    address internal alice   = makeAddr("alice");
    address internal bob     = makeAddr("bob");
    address internal pair    = makeAddr("pair");
    address internal pair2   = makeAddr("pair2");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        pm = new ILPositionManager(router);
        vm.label(address(pm), "ILPositionManager");
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    function _record(address user, uint256 liq, uint256 val) internal {
        vm.prank(router);
        pm.recordDeposit(pair, user, liq, val);
    }

    function _reduce(address user, uint256 liqRemoved)
        internal returns (uint256 propVal, uint256 ts)
    {
        vm.prank(router);
        (propVal, ts) = pm.reducePosition(pair, user, liqRemoved);
    }

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    function test_constructor_setsRouter() public view {
        assertEq(pm.router(), router, "router not set correctly");
    }

    function test_constructor_zeroRouter_reverts() public {
        vm.expectRevert(ILPositionManager.ZeroAddress.selector);
        new ILPositionManager(address(0));
    }

    // -------------------------------------------------------
    // RECORD DEPOSIT - ACCESS CONTROL
    // -------------------------------------------------------

    function test_recordDeposit_onlyRouter_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(ILPositionManager.NotRouter.selector);
        pm.recordDeposit(pair, alice, 100 ether, 1000e6);
    }

    function test_recordDeposit_zeroLiquidity_reverts() public {
        vm.prank(router);
        vm.expectRevert(ILPositionManager.ZeroLiquidity.selector);
        pm.recordDeposit(pair, alice, 0, 1000e6);
    }

    // -------------------------------------------------------
    // RECORD DEPOSIT - FRESH POSITION
    // -------------------------------------------------------

    function test_recordDeposit_fresh_storesCorrectValues() public {
        uint256 liq = 100 ether;
        uint256 val = 1000e6;

        _record(alice, liq, val);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity,      liq,            "liquidity wrong");
        assertEq(p.valueAtDeposit, val,            "valueAtDeposit wrong");
        assertEq(p.timestamp,      block.timestamp, "timestamp wrong");
    }

    function test_recordDeposit_fresh_timestampIsBlockTimestamp() public {
        vm.warp(12345);
        _record(alice, 100 ether, 1000e6);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.timestamp, 12345, "timestamp should be block.timestamp at deposit");
    }

    function test_recordDeposit_fresh_zeroValue_allowed() public {
        // depositValue of 0 is valid — liquidity is what matters
        _record(alice, 100 ether, 0);
        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity, 100 ether, "zero value deposit should still record liquidity");
    }

    function test_recordDeposit_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ILPositionManager.PositionRecorded(pair, alice, 100 ether, 1000e6);

        vm.prank(router);
        pm.recordDeposit(pair, alice, 100 ether, 1000e6);
    }

    // -------------------------------------------------------
    // RECORD DEPOSIT - RE-DEPOSIT (WEIGHTED AVERAGE)
    // -------------------------------------------------------

    function test_recordDeposit_redeposit_weightedAverageValue() public {
        // First deposit: 100 liq @ value 1000
        _record(alice, 100 ether, 1000e6);

        // Second deposit: 100 liq @ value 2000
        _record(alice, 100 ether, 2000e6);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);

        // Expected: (1000 * 100 + 2000 * 100) / 200 = 1500
        assertEq(p.valueAtDeposit, 1500e6, "weighted avg value wrong");
        assertEq(p.liquidity, 200 ether,   "total liquidity wrong");
    }

    function test_recordDeposit_redeposit_weightedAverageTimestamp() public {
        vm.warp(1000);
        _record(alice, 100 ether, 1000e6);

        vm.warp(2000);
        _record(alice, 100 ether, 1000e6);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);

        // Expected: (1000 * 100 + 2000 * 100) / 200 = 1500
        assertEq(p.timestamp, 1500, "weighted avg timestamp wrong");
    }

    function test_recordDeposit_redeposit_smallRedeposit_barelyMovesTimestamp() public {
        vm.warp(1000);
        _record(alice, 1000 ether, 1000e6);  // large initial deposit

        vm.warp(9000);
        _record(alice, 1 ether, 1000e6);     // tiny re-deposit

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);

        // Expected: (1000 * 1000 + 9000 * 1) / 1001 = 1009000 / 1001 ~ 1007
        uint256 expected = uint256(1000 * 1000 + 9000 * 1) / 1001;
        assertApproxEqAbs(p.timestamp, expected, 1, "tiny redeposit should barely move timestamp");

        // Critically: new timestamp should be much closer to original than to new
        assertLt(p.timestamp, 2000, "timestamp should stay close to original deposit time");
    }

    function test_recordDeposit_redeposit_largeRedeposit_movesTimestampSignificantly() public {
        vm.warp(1000);
        _record(alice, 1 ether, 1000e6);     // tiny initial deposit

        vm.warp(9000);
        _record(alice, 1000 ether, 1000e6);  // huge re-deposit

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);

        // Expected: (1000 * 1 + 9000 * 1000) / 1001 ~ 8991
        uint256 expected = uint256(1000 * 1 + 9000 * 1000) / 1001;
        assertApproxEqAbs(p.timestamp, expected, 1, "large redeposit should shift timestamp significantly");

        // New timestamp should be close to the re-deposit time
        assertGt(p.timestamp, 8000, "timestamp should be pulled toward large redeposit time");
    }

    function test_recordDeposit_redeposit_equalAmounts_midpointTimestamp() public {
        vm.warp(1000);
        _record(alice, 100 ether, 1000e6);

        vm.warp(3000);
        _record(alice, 100 ether, 1000e6);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);

        // Equal amounts: midpoint = (1000 + 3000) / 2 = 2000
        assertEq(p.timestamp, 2000, "equal redeposit should give midpoint timestamp");
    }

    function test_recordDeposit_redeposit_liquidityAccumulates() public {
        _record(alice, 100 ether, 1000e6);
        _record(alice, 50 ether,  500e6);
        _record(alice, 25 ether,  250e6);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity, 175 ether, "liquidity should accumulate across deposits");
    }

    // -------------------------------------------------------
    // RECORD DEPOSIT - INDEPENDENCE ACROSS PAIRS AND USERS
    // -------------------------------------------------------

    function test_recordDeposit_differentUsers_independent() public {
        _record(alice, 100 ether, 1000e6);

        vm.prank(router);
        pm.recordDeposit(pair, bob, 200 ether, 2000e6);

        ILPositionManager.Position memory pA = pm.getPosition(pair, alice);
        ILPositionManager.Position memory pB = pm.getPosition(pair, bob);

        assertEq(pA.liquidity, 100 ether, "alice liquidity wrong");
        assertEq(pB.liquidity, 200 ether, "bob liquidity wrong");
    }

    function test_recordDeposit_differentPairs_independent() public {
        _record(alice, 100 ether, 1000e6);

        vm.prank(router);
        pm.recordDeposit(pair2, alice, 200 ether, 2000e6);

        ILPositionManager.Position memory p1 = pm.getPosition(pair,  alice);
        ILPositionManager.Position memory p2 = pm.getPosition(pair2, alice);

        assertEq(p1.liquidity, 100 ether, "pair1 liquidity wrong");
        assertEq(p2.liquidity, 200 ether, "pair2 liquidity wrong");
    }

    // -------------------------------------------------------
    // REDUCE POSITION - ACCESS CONTROL
    // -------------------------------------------------------

    function test_reducePosition_onlyRouter_reverts() public {
        _record(alice, 100 ether, 1000e6);

        vm.prank(stranger);
        vm.expectRevert(ILPositionManager.NotRouter.selector);
        pm.reducePosition(pair, alice, 50 ether);
    }

    function test_reducePosition_noPosition_reverts() public {
        vm.prank(router);
        vm.expectRevert(ILPositionManager.ZeroLiquidity.selector);
        pm.reducePosition(pair, alice, 50 ether);
    }

    function test_reducePosition_excessLiquidity_reverts() public {
        _record(alice, 100 ether, 1000e6);

        vm.prank(router);
        vm.expectRevert(ILPositionManager.InsufficientLiquidity.selector);
        pm.reducePosition(pair, alice, 100 ether + 1);
    }

    // -------------------------------------------------------
    // REDUCE POSITION - FULL WITHDRAWAL
    // -------------------------------------------------------

    function test_reducePosition_full_clearsPosition() public {
        _record(alice, 100 ether, 1000e6);
        _reduce(alice, 100 ether);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity,      0, "liquidity should be 0 after full withdrawal");
        assertEq(p.valueAtDeposit, 0, "value should be 0 after full withdrawal");
        assertEq(p.timestamp,      0, "timestamp should be 0 after full withdrawal");
    }

    function test_reducePosition_full_returnsCorrectProportionalValue() public {
        _record(alice, 100 ether, 1000e6);
        (uint256 propVal,) = _reduce(alice, 100 ether);

        assertEq(propVal, 1000e6, "full withdrawal should return full value");
    }

    function test_reducePosition_full_returnsTimestamp() public {
        vm.warp(5000);
        _record(alice, 100 ether, 1000e6);
        (, uint256 ts) = _reduce(alice, 100 ether);

        assertEq(ts, 5000, "should return position timestamp");
    }

    function test_reducePosition_full_emitsPositionCleared() public {
        _record(alice, 100 ether, 1000e6);

        vm.expectEmit(true, true, false, false);
        emit ILPositionManager.PositionCleared(pair, alice);

        vm.prank(router);
        pm.reducePosition(pair, alice, 100 ether);
    }

    // -------------------------------------------------------
    // REDUCE POSITION - PARTIAL WITHDRAWAL
    // -------------------------------------------------------

    function test_reducePosition_partial_proportionalValue() public {
        _record(alice, 100 ether, 1000e6);

        // Remove 25% of liquidity
        (uint256 propVal,) = _reduce(alice, 25 ether);

        // 25% of 1000e6 = 250e6
        assertEq(propVal, 250e6, "25% withdrawal should return 25% of value");
    }

    function test_reducePosition_partial_reducesLiquidity() public {
        _record(alice, 100 ether, 1000e6);
        _reduce(alice, 25 ether);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity, 75 ether, "remaining liquidity wrong");
    }

    function test_reducePosition_partial_reducesValueProportionally() public {
        _record(alice, 100 ether, 1000e6);
        _reduce(alice, 25 ether);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        // Remaining value = 1000e6 * 75 / 100 = 750e6
        assertEq(p.valueAtDeposit, 750e6, "remaining value wrong after partial withdrawal");
    }

    function test_reducePosition_partial_timestampUnchanged() public {
        vm.warp(5000);
        _record(alice, 100 ether, 1000e6);

        vm.warp(9000);
        _reduce(alice, 25 ether);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.timestamp, 5000, "timestamp must NOT change on withdrawal");
    }

    function test_reducePosition_partial_emitsPositionReduced() public {
        _record(alice, 100 ether, 1000e6);

        vm.expectEmit(true, true, false, true);
        emit ILPositionManager.PositionReduced(pair, alice, 25 ether, 75 ether);

        vm.prank(router);
        pm.reducePosition(pair, alice, 25 ether);
    }

    function test_reducePosition_partial_returnsPositionTimestamp() public {
        vm.warp(5000);
        _record(alice, 100 ether, 1000e6);

        (, uint256 ts) = _reduce(alice, 25 ether);
        assertEq(ts, 5000, "reducePosition should return original timestamp");
    }

    function test_reducePosition_partial_multipleWithdrawals() public {
        _record(alice, 100 ether, 1000e6);

        _reduce(alice, 25 ether);  // remove 25%, 75 remaining
        _reduce(alice, 25 ether);  // remove 25 more, 50 remaining
        _reduce(alice, 50 ether);  // remove last 50, 0 remaining

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity, 0, "position should be fully drained after multiple withdrawals");
    }

    function test_reducePosition_halfThenHalf_valueConsistent() public {
        _record(alice, 100 ether, 2000e6);

        (uint256 val1,) = _reduce(alice, 50 ether);  // first 50%
        (uint256 val2,) = _reduce(alice, 50 ether);  // second 50%

        // val1 = 2000e6 * 50 / 100 = 1000e6
        // val2 = 1000e6 * 50 / 50  = 1000e6
        // total should equal original
        assertApproxEqAbs(val1 + val2, 2000e6, 2, "two halves should sum to original value");
    }

    // -------------------------------------------------------
    // CLEAR POSITION
    // -------------------------------------------------------

    function test_clearPosition_onlyRouter_reverts() public {
        _record(alice, 100 ether, 1000e6);

        vm.prank(stranger);
        vm.expectRevert(ILPositionManager.NotRouter.selector);
        pm.clearPosition(pair, alice);
    }

    function test_clearPosition_deletesPosition() public {
        _record(alice, 100 ether, 1000e6);

        vm.prank(router);
        pm.clearPosition(pair, alice);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity, 0, "position should be cleared");
    }

    function test_clearPosition_onEmptyPosition_noRevert() public {
        // clearPosition on a position that doesn't exist should not revert
        vm.prank(router);
        pm.clearPosition(pair, alice);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity, 0, "empty position clear should be no-op");
    }

    function test_clearPosition_emitsEvent() public {
        _record(alice, 100 ether, 1000e6);

        vm.expectEmit(true, true, false, false);
        emit ILPositionManager.PositionCleared(pair, alice);

        vm.prank(router);
        pm.clearPosition(pair, alice);
    }

    // -------------------------------------------------------
    // GET POSITION
    // -------------------------------------------------------

    function test_getPosition_returnsZeroForNonExistent() public view {
        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity,      0, "nonexistent position liquidity should be 0");
        assertEq(p.valueAtDeposit, 0, "nonexistent position value should be 0");
        assertEq(p.timestamp,      0, "nonexistent position timestamp should be 0");
    }

    function test_getPosition_matchesPublicMapping() public {
        _record(alice, 100 ether, 1000e6);

        ILPositionManager.Position memory via_getPosition = pm.getPosition(pair, alice);
        (uint256 liq, uint256 val, uint256 ts) = pm.positions(pair, alice);

        assertEq(via_getPosition.liquidity,      liq, "liquidity mismatch");
        assertEq(via_getPosition.valueAtDeposit, val, "value mismatch");
        assertEq(via_getPosition.timestamp,      ts,  "timestamp mismatch");
    }

    // -------------------------------------------------------
    // FUZZ
    // -------------------------------------------------------

    function testFuzz_recordDeposit_weightedAvgValueNeverExceedsMaxInput(
        uint256 liq1, uint256 val1,
        uint256 liq2, uint256 val2
    ) public {
        liq1 = bound(liq1, 1 ether,  1_000_000 ether);
        liq2 = bound(liq2, 1 ether,  1_000_000 ether);
        val1 = bound(val1, 0,         1_000_000e6);
        val2 = bound(val2, 0,         1_000_000e6);

        _record(alice, liq1, val1);
        _record(alice, liq2, val2);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);

        uint256 maxVal = val1 > val2 ? val1 : val2;
        assertLe(p.valueAtDeposit, maxVal, "weighted avg value must never exceed max input");
    }

    function testFuzz_recordDeposit_weightedAvgTimestampBounded(
        uint256 ts1, uint256 ts2,
        uint256 liq1, uint256 liq2
    ) public {
        ts1  = bound(ts1,  1,        1_000_000);
        ts2  = bound(ts2,  ts1 + 1,  2_000_000);
        liq1 = bound(liq1, 1 ether,  1_000_000 ether);
        liq2 = bound(liq2, 1 ether,  1_000_000 ether);

        vm.warp(ts1);
        _record(alice, liq1, 1000e6);

        vm.warp(ts2);
        _record(alice, liq2, 1000e6);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);

        // Weighted avg must always be between ts1 and ts2 inclusive
        assertGe(p.timestamp, ts1, "weighted avg timestamp below minimum");
        assertLe(p.timestamp, ts2, "weighted avg timestamp above maximum");
    }

    function testFuzz_reducePosition_proportionalValueNeverExceedsTotal(
        uint256 liq, uint256 val, uint256 removeAmt
    ) public {
        liq       = bound(liq,       2 ether, 1_000_000 ether);
        val       = bound(val,       1,       1_000_000e6);
        removeAmt = bound(removeAmt, 1 ether, liq);

        _record(alice, liq, val);
        (uint256 propVal,) = _reduce(alice, removeAmt);

        assertLe(propVal, val, "proportional value must never exceed total deposit value");
    }

    function testFuzz_reducePosition_remainingLiquidityCorrect(
        uint256 liq, uint256 removeAmt
    ) public {
        liq       = bound(liq,       2 ether, 1_000_000 ether);
        removeAmt = bound(removeAmt, 1,       liq - 1);  // partial only

        _record(alice, liq, 1000e6);
        _reduce(alice, removeAmt);

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.liquidity, liq - removeAmt, "remaining liquidity wrong");
    }

    function testFuzz_reducePosition_timestampAlwaysPreserved(
        uint256 depositTs, uint256 withdrawTs, uint256 liq
    ) public {
        depositTs  = bound(depositTs,  1,              1_000_000);
        withdrawTs = bound(withdrawTs, depositTs + 1,  2_000_000);
        liq        = bound(liq,        2 ether,        1_000_000 ether);

        vm.warp(depositTs);
        _record(alice, liq, 1000e6);

        vm.warp(withdrawTs);
        (, uint256 returnedTs) = _reduce(alice, liq / 2);

        assertEq(returnedTs, depositTs, "timestamp must always be deposit time, not withdrawal time");

        ILPositionManager.Position memory p = pm.getPosition(pair, alice);
        assertEq(p.timestamp, depositTs, "stored timestamp must not change on withdrawal");
    }
}