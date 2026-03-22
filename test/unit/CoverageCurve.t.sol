// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {CoverageCurve}  from "../../src/CoverageCurve.sol";

contract CoverageCurveHarness {
    function compute(
        uint256 tierCeilingBps,
        uint256 secondsInPool,
        uint256 vaultUSDCReserve,
        uint256 totalExposureUSDC
    ) external pure returns (uint256) {
        return CoverageCurve.compute(
            tierCeilingBps,
            secondsInPool,
            vaultUSDCReserve,
            totalExposureUSDC
        );
    }

    function expSaturationBps(uint256 t) external pure returns (uint256) {
        return CoverageCurve._expSaturationBps(t);
    }

    function vaultHealthBps(uint256 reserve, uint256 exposure)
        external pure returns (uint256)
    {
        return CoverageCurve._vaultHealthBps(reserve, exposure);
    }
}

contract CoverageCurveTest is Test {

    CoverageCurveHarness internal curve;

    uint256 internal constant VOLATILE_CEILING = 7500;
    uint256 internal constant BLUECHIP_CEILING = 5000;
    uint256 internal constant STABLE_CEILING   = 1500;
    uint256 internal constant MIN_LOCK         = 7 days;
    uint256 internal constant FULL_HEALTH      = 1_000_000e6;

    function setUp() public {
        curve = new CoverageCurveHarness();
    }

    // -------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------

    function test_constants_minLockIs7Days() public pure {
        assertEq(CoverageCurve.MIN_LOCK_SECONDS, 7 days);
    }

    function test_constants_timeConstantIs60Days() public pure {
        assertEq(CoverageCurve.TIME_CONSTANT_SECONDS, 60 days);
    }

    // -------------------------------------------------------
    // EXP SATURATION - EXACT BREAKPOINTS
    // -------------------------------------------------------

    function test_expSaturation_at0days_returns0() public view {
        assertEq(curve.expSaturationBps(0), 0);
    }

    function test_expSaturation_at7days_exact() public view {
        uint256 result = curve.expSaturationBps(7 days);
        assertEq(result, 1101, "7d breakpoint must be exactly 1101");
    }

    function test_expSaturation_at30days_exact() public view {
        uint256 result = curve.expSaturationBps(30 days);
        assertEq(result, 3935, "30d breakpoint must be exactly 3935");
    }

    function test_expSaturation_at60days_exact() public view {
        uint256 result = curve.expSaturationBps(60 days);
        assertEq(result, 6321, "60d breakpoint must be exactly 6321");
    }

    function test_expSaturation_at90days_exact() public view {
        uint256 result = curve.expSaturationBps(90 days);
        assertEq(result, 7769, "90d breakpoint must be exactly 7769");
    }

    function test_expSaturation_at120days_exact() public view {
        uint256 result = curve.expSaturationBps(120 days);
        assertEq(result, 8647, "120d breakpoint must be exactly 8647");
    }

    function test_expSaturation_at150days_exact() public view {
        uint256 result = curve.expSaturationBps(150 days);
        assertEq(result, 9179, "150d breakpoint must be exactly 9179");
    }

    function test_expSaturation_at180days_exact() public view {
        uint256 result = curve.expSaturationBps(180 days);
        assertEq(result, 9502, "180d breakpoint must be exactly 9502");
    }

    function test_expSaturation_at210days_exact() public view {
        uint256 result = curve.expSaturationBps(210 days);
        assertEq(result, 9698, "210d breakpoint must be exactly 9698");
    }

    function test_expSaturation_at240days_clamped() public view {
        uint256 result = curve.expSaturationBps(240 days);
        assertEq(result, 9800, "240d must be clamped at 9800");
    }

    function test_expSaturation_at365days_clamped() public view {
        uint256 result = curve.expSaturationBps(365 days);
        assertEq(result, 9800, "365d must be clamped at 9800");
    }

    function test_expSaturation_extremeTime_clamped() public view {
        uint256 result = curve.expSaturationBps(3650 days);
        assertEq(result, 9800, "extreme time must clamp at 9800");
    }

    // -------------------------------------------------------
    // EXP SATURATION - INTERPOLATION CORRECTNESS
    // -------------------------------------------------------

    function test_expSaturation_midpoint_7d_30d() public view {
        // Midpoint between 7d and 30d = 18.5d
        // Expected: 1101 + (3935 - 1101) * (18.5d - 7d) / (30d - 7d)
        uint256 t = 7 days + (30 days - 7 days) / 2;
        uint256 result = curve.expSaturationBps(t);
        uint256 expected = 1101 + (3935 - 1101) * (t - 7 days) / (30 days - 7 days);
        assertEq(result, expected, "interpolation wrong in 7d-30d segment");
    }

    function test_expSaturation_midpoint_30d_60d() public view {
        uint256 t = 30 days + (60 days - 30 days) / 2;
        uint256 result = curve.expSaturationBps(t);
        uint256 expected = 3935 + (6321 - 3935) * (t - 30 days) / (60 days - 30 days);
        assertEq(result, expected, "interpolation wrong in 30d-60d segment");
    }

    function test_expSaturation_midpoint_60d_90d() public view {
        uint256 t = 60 days + (90 days - 60 days) / 2;
        uint256 result = curve.expSaturationBps(t);
        uint256 expected = 6321 + (7769 - 6321) * (t - 60 days) / (90 days - 60 days);
        assertEq(result, expected, "interpolation wrong in 60d-90d segment");
    }

    function test_expSaturation_midpoint_90d_120d() public view {
        uint256 t = 90 days + (120 days - 90 days) / 2;
        uint256 result = curve.expSaturationBps(t);
        uint256 expected = 7769 + (8647 - 7769) * (t - 90 days) / (120 days - 90 days);
        assertEq(result, expected, "interpolation wrong in 90d-120d segment");
    }

    function test_expSaturation_midpoint_120d_150d() public view {
        uint256 t = 120 days + (150 days - 120 days) / 2;
        uint256 result = curve.expSaturationBps(t);
        uint256 expected = 8647 + (9179 - 8647) * (t - 120 days) / (150 days - 120 days);
        assertEq(result, expected, "interpolation wrong in 120d-150d segment");
    }

    function test_expSaturation_midpoint_150d_180d() public view {
        uint256 t = 150 days + (180 days - 150 days) / 2;
        uint256 result = curve.expSaturationBps(t);
        uint256 expected = 9179 + (9502 - 9179) * (t - 150 days) / (180 days - 150 days);
        assertEq(result, expected, "interpolation wrong in 150d-180d segment");
    }

    function test_expSaturation_midpoint_180d_210d() public view {
        uint256 t = 180 days + (210 days - 180 days) / 2;
        uint256 result = curve.expSaturationBps(t);
        uint256 expected = 9502 + (9698 - 9502) * (t - 180 days) / (210 days - 180 days);
        assertEq(result, expected, "interpolation wrong in 180d-210d segment");
    }

    function test_expSaturation_midpoint_210d_240d() public view {
        uint256 t = 210 days + (240 days - 210 days) / 2;
        uint256 result = curve.expSaturationBps(t);
        uint256 expected = 9698 + (9800 - 9698) * (t - 210 days) / (240 days - 210 days);
        assertEq(result, expected, "interpolation wrong in 210d-240d segment");
    }

    // -------------------------------------------------------
    // EXP SATURATION - MONOTONE AND BOUNDS
    // -------------------------------------------------------

    function test_expSaturation_strictlyMonotoneAcrossAllBreakpoints() public view {
        uint256 r7   = curve.expSaturationBps(7 days);
        uint256 r30  = curve.expSaturationBps(30 days);
        uint256 r60  = curve.expSaturationBps(60 days);
        uint256 r90  = curve.expSaturationBps(90 days);
        uint256 r120 = curve.expSaturationBps(120 days);
        uint256 r150 = curve.expSaturationBps(150 days);
        uint256 r180 = curve.expSaturationBps(180 days);
        uint256 r210 = curve.expSaturationBps(210 days);
        uint256 r240 = curve.expSaturationBps(240 days);

        assertLt(r7,   r30,  "7d < 30d");
        assertLt(r30,  r60,  "30d < 60d");
        assertLt(r60,  r90,  "60d < 90d");
        assertLt(r90,  r120, "90d < 120d");
        assertLt(r120, r150, "120d < 150d");
        assertLt(r150, r180, "150d < 180d");
        assertLt(r180, r210, "180d < 210d");
        assertLt(r210, r240, "210d < 240d");
    }

    function test_expSaturation_neverExceeds9800() public view {
        uint256[10] memory times = [
            uint256(7 days),
            uint256(30 days),
            uint256(60 days),
            uint256(90 days),
            uint256(120 days),
            uint256(150 days),
            uint256(180 days),
            uint256(210 days),
            uint256(240 days),
            uint256(365 days)
        ];
        for (uint256 i = 0; i < 10; i++) {
            assertLe(
                curve.expSaturationBps(times[i]),
                9800,
                "must never exceed 9800"
            );
        }
    }

    function test_expSaturation_neverReturns10000() public view {
        assertLt(curve.expSaturationBps(365 days),  10000);
        assertLt(curve.expSaturationBps(3650 days), 10000);
    }

    function test_expSaturation_concaveCurve_gainDecreases() public view {
        uint256 r7d  = curve.expSaturationBps(7 days);
        uint256 r30d = curve.expSaturationBps(30 days);
        uint256 r60d = curve.expSaturationBps(60 days);
        uint256 r90d = curve.expSaturationBps(90 days);

        uint256 gain_7_30  = r30d - r7d;
        uint256 gain_30_60 = r60d - r30d;
        uint256 gain_60_90 = r90d - r60d;

        assertGt(gain_7_30,  gain_30_60, "early gain must exceed mid gain");
        assertGt(gain_30_60, gain_60_90, "mid gain must exceed late gain");
    }

    // -------------------------------------------------------
    // VAULT HEALTH - BOUNDARY CONDITIONS
    // -------------------------------------------------------

    function test_vaultHealth_zeroExposure_returns10000() public view {
        assertEq(curve.vaultHealthBps(0, 0),          10000);
        assertEq(curve.vaultHealthBps(1_000_000e6, 0), 10000);
    }

    function test_vaultHealth_zeroReserve_nonZeroExposure_returnsZero() public view {
        assertEq(curve.vaultHealthBps(0, 100_000e6), 0);
    }

    function test_vaultHealth_reserveEqualsTarget_returns10000() public view {
        uint256 exposure      = 100_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        assertEq(curve.vaultHealthBps(targetReserve, exposure), 10000);
    }

    function test_vaultHealth_reserveAboveTarget_returns10000() public view {
        uint256 exposure = 100_000e6;
        uint256 reserve  = exposure * 10;
        assertEq(curve.vaultHealthBps(reserve, exposure), 10000);
    }

    function test_vaultHealth_reserveOneWeiBelow_target_notFull() public view {
        uint256 exposure      = 100_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        uint256 result        = curve.vaultHealthBps(targetReserve - 1, exposure);
        assertLt(result, 10000, "one wei below target must not return full health");
    }

    // -------------------------------------------------------
    // VAULT HEALTH - LINEAR SCALE
    // -------------------------------------------------------

    function test_vaultHealth_halfTarget_returns5000() public view {
        uint256 exposure      = 100_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        uint256 reserve       = targetReserve / 2;
        assertEq(curve.vaultHealthBps(reserve, exposure), 5000);
    }

    function test_vaultHealth_quarterTarget_returns2500() public view {
        uint256 exposure      = 100_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        uint256 reserve       = targetReserve / 4;
        assertEq(curve.vaultHealthBps(reserve, exposure), 2500);
    }

    function test_vaultHealth_threeQuarterTarget_returns7500() public view {
        uint256 exposure      = 100_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        uint256 reserve       = (targetReserve * 3) / 4;
        assertEq(curve.vaultHealthBps(reserve, exposure), 7500);
    }

    function test_vaultHealth_tenPercentTarget_returns1000() public view {
        uint256 exposure      = 100_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        uint256 reserve       = targetReserve / 10;
        assertEq(curve.vaultHealthBps(reserve, exposure), 1000);
    }

    function test_vaultHealth_linearityVerified() public view {
        uint256 exposure = 200_000e6;
        uint256 target   = (exposure * 3) / 2;

        uint256 h25  = curve.vaultHealthBps((target * 25) / 100, exposure);
        uint256 h50  = curve.vaultHealthBps((target * 50) / 100, exposure);
        uint256 h75  = curve.vaultHealthBps((target * 75) / 100, exposure);
        uint256 h100 = curve.vaultHealthBps(target,               exposure);

        assertApproxEqAbs(h25,  2500,  2);
        assertApproxEqAbs(h50,  5000,  2);
        assertApproxEqAbs(h75,  7500,  2);
        assertEq         (h100, 10000);
    }

    // -------------------------------------------------------
    // COMPUTE - MIN LOCK GUARD
    // -------------------------------------------------------

    function test_compute_zeroDays_returnsZero() public view {
        assertEq(curve.compute(7500, 0, FULL_HEALTH, 0), 0);
    }

    function test_compute_oneDayBelowLock_returnsZero() public view {
        assertEq(curve.compute(7500, MIN_LOCK - 1, FULL_HEALTH, 0), 0);
    }

    function test_compute_oneSecondBelowLock_returnsZero() public view {
        assertEq(curve.compute(7500, MIN_LOCK - 1, FULL_HEALTH, 0), 0);
    }

    function test_compute_exactlyAtMinLock_nonZero() public view {
        assertGt(curve.compute(7500, MIN_LOCK, FULL_HEALTH, 0), 0);
    }

    // -------------------------------------------------------
    // COMPUTE - CEILING NEVER EXCEEDED
    // -------------------------------------------------------

    function test_compute_volatileCeiling_neverExceeded() public view {
        assertLe(curve.compute(VOLATILE_CEILING, 365 days, FULL_HEALTH, 0), VOLATILE_CEILING);
    }

    function test_compute_bluechipCeiling_neverExceeded() public view {
        assertLe(curve.compute(BLUECHIP_CEILING, 365 days, FULL_HEALTH, 0), BLUECHIP_CEILING);
    }

    function test_compute_stableCeiling_neverExceeded() public view {
        assertLe(curve.compute(STABLE_CEILING, 365 days, FULL_HEALTH, 0), STABLE_CEILING);
    }

    function test_compute_zeroCeiling_alwaysZero() public view {
        assertEq(curve.compute(0, 365 days, FULL_HEALTH, 0), 0);
    }

    // -------------------------------------------------------
    // COMPUTE - CORRECT VALUES AT KEY TIMES
    // -------------------------------------------------------

    function test_compute_7days_volatile_fullHealth() public view {
        uint256 result = curve.compute(VOLATILE_CEILING, 7 days, FULL_HEALTH, 0);
        // timeBps=1101, healthBps=10000
        // result = 7500 * 1101 / 10000 * 10000 / 10000 = 825
        assertEq(result, 825, "7d volatile full health wrong");
    }

    function test_compute_30days_volatile_fullHealth() public view {
        uint256 result = curve.compute(VOLATILE_CEILING, 30 days, FULL_HEALTH, 0);
        // 7500 * 3935 / 10000 = 2951
        assertEq(result, 2951, "30d volatile full health wrong");
    }

    function test_compute_60days_volatile_fullHealth() public view {
        uint256 result = curve.compute(VOLATILE_CEILING, 60 days, FULL_HEALTH, 0);
        // 7500 * 6321 / 10000 = 4740
        assertEq(result, 4740, "60d volatile full health wrong");
    }

    function test_compute_90days_volatile_fullHealth() public view {
        uint256 result = curve.compute(VOLATILE_CEILING, 90 days, FULL_HEALTH, 0);
        // 7500 * 7769 / 10000 = 5826
        assertEq(result, 5826, "90d volatile full health wrong");
    }

    function test_compute_180days_volatile_fullHealth() public view {
        uint256 result = curve.compute(VOLATILE_CEILING, 180 days, FULL_HEALTH, 0);
        // 7500 * 9502 / 10000 = 7126
        assertEq(result, 7126, "180d volatile full health wrong");
    }

    function test_compute_240days_volatile_fullHealth() public view {
        uint256 result = curve.compute(VOLATILE_CEILING, 240 days, FULL_HEALTH, 0);
        // 7500 * 9800 / 10000 = 7350
        assertEq(result, 7350, "240d volatile full health wrong");
    }

    // -------------------------------------------------------
    // COMPUTE - VAULT HEALTH INTERACTION
    // -------------------------------------------------------

    function test_compute_zeroReserve_returnsZero() public view {
        assertEq(curve.compute(7500, 60 days, 0, 100_000e6), 0);
    }

    function test_compute_halfHealth_halvesOutput() public view {
        uint256 exposure      = 1_000_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        uint256 halfReserve   = targetReserve / 2;

        uint256 full = curve.compute(VOLATILE_CEILING, 60 days, FULL_HEALTH, 0);
        uint256 half = curve.compute(VOLATILE_CEILING, 60 days, halfReserve, exposure);

        assertApproxEqRel(half, full / 2, 0.01e18, "half health should halve output");
    }

    function test_compute_quarterHealth_quartersOutput() public view {
        uint256 exposure      = 1_000_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        uint256 quarterReserve = targetReserve / 4;

        uint256 full    = curve.compute(VOLATILE_CEILING, 60 days, FULL_HEALTH, 0);
        uint256 quarter = curve.compute(VOLATILE_CEILING, 60 days, quarterReserve, exposure);

        assertApproxEqRel(quarter, full / 4, 0.01e18, "quarter health should quarter output");
    }

    function test_compute_stressedVault_lowButNonZero() public view {
        uint256 exposure      = 1_000_000e6;
        uint256 targetReserve = (exposure * 3) / 2;
        uint256 tenPct        = targetReserve / 10;

        uint256 result = curve.compute(VOLATILE_CEILING, 90 days, tenPct, exposure);
        assertGt(result, 0,                "stressed vault should still give some coverage");
        assertLt(result, VOLATILE_CEILING, "stressed vault must not reach ceiling");
    }

    // -------------------------------------------------------
    // COMPUTE - TIER ORDERING
    // -------------------------------------------------------

    function test_compute_tierOrdering_90days_fullHealth() public view {
        uint256 vol  = curve.compute(VOLATILE_CEILING, 90 days, FULL_HEALTH, 0);
        uint256 blue = curve.compute(BLUECHIP_CEILING, 90 days, FULL_HEALTH, 0);
        uint256 stbl = curve.compute(STABLE_CEILING,   90 days, FULL_HEALTH, 0);

        assertGt(vol,  blue, "volatile > bluechip");
        assertGt(blue, stbl, "bluechip > stable");
    }

    function test_compute_proportionalToCeiling() public view {
        uint256 r10000 = curve.compute(10000, 60 days, FULL_HEALTH, 0);
        uint256 r5000  = curve.compute(5000,  60 days, FULL_HEALTH, 0);

        assertApproxEqRel(r10000, r5000 * 2, 0.001e18, "output must scale proportionally with ceiling");
    }

    // -------------------------------------------------------
    // COMPUTE - MONOTONE WITH TIME
    // -------------------------------------------------------

    function test_compute_strictlyMonotoneWithTime() public view {
        uint256 r7d   = curve.compute(VOLATILE_CEILING, 7 days,   FULL_HEALTH, 0);
        uint256 r30d  = curve.compute(VOLATILE_CEILING, 30 days,  FULL_HEALTH, 0);
        uint256 r60d  = curve.compute(VOLATILE_CEILING, 60 days,  FULL_HEALTH, 0);
        uint256 r90d  = curve.compute(VOLATILE_CEILING, 90 days,  FULL_HEALTH, 0);
        uint256 r120d = curve.compute(VOLATILE_CEILING, 120 days, FULL_HEALTH, 0);
        uint256 r150d = curve.compute(VOLATILE_CEILING, 150 days, FULL_HEALTH, 0);
        uint256 r180d = curve.compute(VOLATILE_CEILING, 180 days, FULL_HEALTH, 0);
        uint256 r210d = curve.compute(VOLATILE_CEILING, 210 days, FULL_HEALTH, 0);
        uint256 r240d = curve.compute(VOLATILE_CEILING, 240 days, FULL_HEALTH, 0);

        assertLt(r7d,   r30d,  "7d < 30d");
        assertLt(r30d,  r60d,  "30d < 60d");
        assertLt(r60d,  r90d,  "60d < 90d");
        assertLt(r90d,  r120d, "90d < 120d");
        assertLt(r120d, r150d, "120d < 150d");
        assertLt(r150d, r180d, "150d < 180d");
        assertLt(r180d, r210d, "180d < 210d");
        assertLt(r210d, r240d, "210d < 240d");
    }

    // -------------------------------------------------------
    // FUZZ
    // -------------------------------------------------------

    function testFuzz_expSaturation_neverExceeds9800(uint256 t) public view {
        t = bound(t, 0, 3650 days);
        assertLe(curve.expSaturationBps(t), 9800);
    }

    function testFuzz_expSaturation_monotoneInValidRange(
        uint256 t1,
        uint256 t2
    ) public view {
        t1 = bound(t1, 0,        239 days);
        t2 = bound(t2, t1 + 1,  240 days);

        uint256 r1 = curve.expSaturationBps(t1);
        uint256 r2 = curve.expSaturationBps(t2);

        assertLe(r1, r2, "expSaturation must be non-decreasing");
    }

    function testFuzz_vaultHealth_neverExceeds10000(
        uint256 reserve,
        uint256 exposure
    ) public view {
        reserve  = bound(reserve,  0, type(uint128).max);
        exposure = bound(exposure, 0, type(uint128).max);
        assertLe(curve.vaultHealthBps(reserve, exposure), 10000);
    }

    function testFuzz_vaultHealth_zeroReserve_alwaysZero(uint256 exposure) public view {
        exposure = bound(exposure, 1, type(uint128).max);
        assertEq(curve.vaultHealthBps(0, exposure), 0);
    }

    function testFuzz_vaultHealth_aboveTarget_always10000(
        uint256 exposure,
        uint256 multiplierBps
    ) public view {
        exposure      = bound(exposure,      1,    type(uint64).max);
        // multiplierBps in range [15000, 30000] means 1.5x to 3.0x exposure
        multiplierBps = bound(multiplierBps, 15000, 30000);
        uint256 reserve = (exposure * multiplierBps) / 10000;
        assertEq(curve.vaultHealthBps(reserve, exposure), 10000);
    }

    function testFuzz_compute_neverExceedsCeiling(
        uint256 ceiling,
        uint256 t,
        uint256 reserve,
        uint256 exposure
    ) public view {
        ceiling  = bound(ceiling,  0, 10000);
        t        = bound(t,        0, 3650 days);
        reserve  = bound(reserve,  0, type(uint128).max);
        exposure = bound(exposure, 0, type(uint128).max);

        uint256 result = curve.compute(ceiling, t, reserve, exposure);
        assertLe(result, ceiling, "CRITICAL: output must never exceed ceiling");
    }

    function testFuzz_compute_belowMinLock_alwaysZero(
        uint256 ceiling,
        uint256 t
    ) public view {
        ceiling = bound(ceiling, 0, 10000);
        t       = bound(t,       0, MIN_LOCK - 1);

        assertEq(curve.compute(ceiling, t, FULL_HEALTH, 0), 0);
    }

    function testFuzz_compute_monotoneWithTime(
        uint256 ceiling,
        uint256 t1,
        uint256 t2,
        uint256 reserve,
        uint256 exposure
    ) public view {
        ceiling  = bound(ceiling,  1,       10000);
        t1       = bound(t1,       MIN_LOCK, 239 days);
        t2       = bound(t2,       t1 + 1,  240 days);
        reserve  = bound(reserve,  1,        type(uint64).max);
        exposure = bound(exposure, 0,        reserve);

        uint256 r1 = curve.compute(ceiling, t1, reserve, exposure);
        uint256 r2 = curve.compute(ceiling, t2, reserve, exposure);

        assertLe(r1, r2, "coverage must be non-decreasing with time");
    }

    function testFuzz_compute_proportionalToCeiling(
        uint256 ceiling1,
        uint256 ceiling2,
        uint256 t
    ) public view {
        ceiling1 = bound(ceiling1, 1,    5000);
        ceiling2 = ceiling1 * 2;
        if (ceiling2 > 10000) return;
        t        = bound(t, MIN_LOCK, 240 days);

        uint256 r1 = curve.compute(ceiling1, t, FULL_HEALTH, 0);
        uint256 r2 = curve.compute(ceiling2, t, FULL_HEALTH, 0);

        assertApproxEqAbs(r2, r1 * 2, 2, "output must scale linearly with ceiling");
    }

    function testFuzz_vaultHealth_linear(
        uint256 exposure,
        uint256 pctBps
    ) public view {
        exposure = bound(exposure, 1000e6,  type(uint64).max);
        pctBps   = bound(pctBps,   1,       9999);

        uint256 target  = (exposure * 3) / 2;
        uint256 reserve = (target * pctBps) / 10000;

        uint256 result = curve.vaultHealthBps(reserve, exposure);

        assertLe(result, 10000, "must not exceed 10000");
        assertApproxEqAbs(result, pctBps, 2, "health must be linear with reserve");
    }
}