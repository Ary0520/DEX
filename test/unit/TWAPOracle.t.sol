// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2}  from "forge-std/Test.sol";
import {TWAPOracle}      from "../../src/TWAPOracle.sol";
import {MockERC20}       from "../mocks/MockERC20.sol";
import {Factory}         from "../../src/FactoryContract.sol";
import {Pair}            from "../../src/Pair.sol";

contract TWAPOracleTest is Test {

    TWAPOracle internal oracle;
    Factory    internal factory;
    MockERC20  internal tokenA;
    MockERC20  internal tokenB;
    address    internal pair;

    address internal owner   = makeAddr("owner");
    address internal keeper  = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    // -------------------------------------------------------
    // SETUP
    // -------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);
        oracle  = new TWAPOracle();
        factory = new Factory();
        vm.stopPrank();

        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        tokenA.mint(owner, 1_000_000 ether);
        tokenB.mint(owner, 1_000_000 ether);

        pair = factory.createPair(address(tokenA), address(tokenB));

        // Seed liquidity so reserves are non-zero (required for TWAP accumulation)
        vm.startPrank(owner);
        tokenA.transfer(pair, 100 ether);
        tokenB.transfer(pair, 400 ether);
        Pair(pair).mint(owner);
        vm.stopPrank();

        vm.label(address(oracle),  "TWAPOracle");
        vm.label(address(factory), "Factory");
        vm.label(pair,             "Pair");
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    /// @dev Take first snapshot, advance past MIN_TWAP_WINDOW, ready to read
    function _bootstrapOracle() internal {
        vm.prank(owner);
        oracle.update(pair);
        // Advance past MIN_TWAP_WINDOW so reads don't revert TWAPWindowTooSmall
        vm.warp(block.timestamp + 31 minutes);
    }

    /// @dev Bootstrap + advance past MAX_STALENESS
    function _bootstrapAndStale() internal {
        _bootstrapOracle();
        vm.warp(block.timestamp + 9 hours);
    }

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    function test_constructor_ownerIsDeployer() public view {
        assertEq(oracle.owner(), owner, "owner should be deployer");
    }

    // -------------------------------------------------------
    // UPDATE - PERMISSIONLESS
    // -------------------------------------------------------

    function test_update_anyoneCanUpdate() public {
        vm.prank(stranger);
        oracle.update(pair);
        (,, uint256 ts) = oracle.observations(pair);
        assertEq(ts, block.timestamp, "observation timestamp wrong");
    }

    function test_update_ownerCanUpdate() public {
        vm.prank(owner);
        oracle.update(pair);
        (,, uint256 ts) = oracle.observations(pair);
        assertEq(ts, block.timestamp, "observation timestamp wrong");
    }

    // -------------------------------------------------------
    // UPDATE - RATE LIMITING
    // -------------------------------------------------------

    function test_update_firstUpdateAlwaysSucceeds() public {
        // Fresh pair — obs.timestamp == 0, TooSoon check is skipped
        vm.prank(owner);
        oracle.update(pair);
        (,, uint256 ts) = oracle.observations(pair);
        assertGt(ts, 0, "first update should record timestamp");
    }

    function test_update_secondUpdateWithinInterval_reverts() public {
        vm.prank(owner);
        oracle.update(pair);

        // Advance only 1 hour — still within 2 hour MAX_UPDATE_WINDOW
        vm.warp(block.timestamp + 1 hours);

        vm.prank(owner);
        vm.expectRevert(TWAPOracle.UpdateTooSoon.selector);
        oracle.update(pair);
    }

    function test_update_exactlyAtInterval_succeeds() public {
        vm.prank(owner);
        oracle.update(pair);

        // At exactly MAX_UPDATE_WINDOW: condition is windowSize < MAX_UPDATE_WINDOW
        // 7200 < 7200 = false — so update succeeds
        vm.warp(block.timestamp + 2 hours);

        vm.prank(owner);
        oracle.update(pair);

        (,, uint256 ts) = oracle.observations(pair);
        assertEq(ts, block.timestamp, "update at exact interval boundary should succeed");
    }

    function test_update_afterInterval_succeeds() public {
        vm.prank(owner);
        oracle.update(pair);

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(owner);
        oracle.update(pair);

        (,, uint256 ts) = oracle.observations(pair);
        assertEq(ts, block.timestamp, "second update should record new timestamp");
    }

    function test_update_snapshotsCumulativePrices() public {
        // Advance time so cumulative prices have accumulated
        vm.warp(block.timestamp + 1 hours);
        Pair(pair).sync();

        vm.prank(owner);
        oracle.update(pair);

        (uint256 cum0, uint256 cum1,) = oracle.observations(pair);
        assertGt(cum0, 0, "price0Cumulative should be non-zero");
        assertGt(cum1, 0, "price1Cumulative should be non-zero");
    }

    function test_update_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TWAPOracle.OracleUpdated(pair, block.timestamp, owner);

        vm.prank(owner);
        oracle.update(pair);
    }

    function test_update_overwritesPreviousObservation() public {
        vm.prank(owner);
        oracle.update(pair);
        (,, uint256 ts1) = oracle.observations(pair);

        vm.warp(block.timestamp + 3 hours);
        Pair(pair).sync();

        vm.prank(owner);
        oracle.update(pair);
        (,, uint256 ts2) = oracle.observations(pair);

        assertGt(ts2, ts1, "second observation should have later timestamp");
    }

    // -------------------------------------------------------
    // GET TWAP - NO OBSERVATION
    // -------------------------------------------------------

    function test_getTWAP_noObservation_reverts() public {
        vm.expectRevert(TWAPOracle.NoObservation.selector);
        oracle.getTWAP(pair);
    }

    function test_getTWAP0_noObservation_reverts() public {
        vm.expectRevert(TWAPOracle.NoObservation.selector);
        oracle.getTWAP0(pair);
    }

    function test_getTWAP1_noObservation_reverts() public {
        vm.expectRevert(TWAPOracle.NoObservation.selector);
        oracle.getTWAP1(pair);
    }

    function test_getTWAPForTokens_noObservation_reverts() public {
        vm.expectRevert(TWAPOracle.NoObservation.selector);
        oracle.getTWAPForTokens(pair, address(tokenA));
    }

    // -------------------------------------------------------
    // GET TWAP - MINIMUM WINDOW
    // -------------------------------------------------------

    function test_getTWAP_windowTooSmall_reverts() public {
        vm.prank(owner);
        oracle.update(pair);
        // No time advance — timeElapsed = 0 < MIN_TWAP_WINDOW
        vm.expectRevert(TWAPOracle.TWAPWindowTooSmall.selector);
        oracle.getTWAP(pair);
    }

    function test_getTWAP_justBelowMinWindow_reverts() public {
        vm.prank(owner);
        oracle.update(pair);

        vm.warp(block.timestamp + 29 minutes + 59);

        vm.expectRevert(TWAPOracle.TWAPWindowTooSmall.selector);
        oracle.getTWAP(pair);
    }

    function test_getTWAP_atMinWindow_succeeds() public {
        vm.prank(owner);
        oracle.update(pair);

        // Advance time and accumulate prices in pair
        vm.warp(block.timestamp + 30 minutes);
        Pair(pair).sync();

        // Should succeed now — timeElapsed >= MIN_TWAP_WINDOW
        uint256 price = oracle.getTWAP(pair);
        assertGt(price, 0, "TWAP should be non-zero");
    }

    // -------------------------------------------------------
    // GET TWAP - STALENESS
    // -------------------------------------------------------

    function test_getTWAP_stalePrice_reverts() public {
        _bootstrapOracle();
        // Advance past MAX_STALENESS (8 hours)
        vm.warp(block.timestamp + 8 hours + 1);
        vm.expectRevert(TWAPOracle.StalePrice.selector);
        oracle.getTWAP(pair);
    }

    function test_getTWAP_withinStaleness_succeeds() public {
        // Take fresh snapshot, then read within MAX_STALENESS window
        vm.prank(owner);
        oracle.update(pair);
        // obs.timestamp = 1
        // Advance to exactly obs.timestamp + MAX_STALENESS (not beyond)
        vm.warp(1 + 8 hours);
        Pair(pair).sync();
        // condition: timeElapsed > MAX_STALENESS
        // 28800 > 28800 = false — should NOT revert
        uint256 price = oracle.getTWAP(pair);
        assertGt(price, 0, "price at exactly staleness boundary should succeed");
    }

    function test_getTWAP_justBeyondStaleness_reverts() public {
        _bootstrapOracle();
        vm.warp(block.timestamp + 8 hours + 1);
        vm.expectRevert(TWAPOracle.StalePrice.selector);
        oracle.getTWAP(pair);
    }

    function test_getTWAP_refreshAfterStale_succeeds() public {
        _bootstrapOracle();
        vm.warp(block.timestamp + 8 hours + 1);

        // Re-update the oracle
        vm.prank(owner);
        oracle.update(pair);

        vm.warp(block.timestamp + 31 minutes);
        Pair(pair).sync();

        uint256 price = oracle.getTWAP(pair);
        assertGt(price, 0, "price should be valid after re-update");
    }

    // -------------------------------------------------------
    // GET TWAP - PRICE CORRECTNESS
    // -------------------------------------------------------

    function test_getTWAP0_reflectsReserveRatio() public {
        // Pair has 100 tokenA : 400 tokenB
        // price0 = reserve1/reserve0 = 400/100 = 4.0 (scaled by 1e18)
        _bootstrapOracle();

        uint256 warpBy = 1 hours;
        vm.warp(block.timestamp + warpBy);
        Pair(pair).sync();

        uint256 price0 = oracle.getTWAP0(pair);
        assertGt(price0, 0, "price0 should be non-zero");

        // Expected: ~4e18 if tokenA is token0, ~0.25e18 if tokenA is token1
        address t0 = Pair(pair).token0();
        uint256 expectedPrice = address(tokenA) == t0
            ? (400 ether * 1e18) / 100 ether
            : (100 ether * 1e18) / 400 ether;

        assertApproxEqRel(price0, expectedPrice, 0.02e18, "TWAP0 ratio wrong");
    }

    function test_getTWAP1_isInverseOfTWAP0() public {
        _bootstrapOracle();

        vm.warp(block.timestamp + 1 hours);
        Pair(pair).sync();

        uint256 price0 = oracle.getTWAP0(pair);
        uint256 price1 = oracle.getTWAP1(pair);

        assertGt(price0, 0, "price0 zero");
        assertGt(price1, 0, "price1 zero");

        // price0 * price1 should approximately equal 1e36 (they are inverses)
        // Allow 2% tolerance for integer math
        uint256 product = (price0 * price1) / 1e18;
        assertApproxEqRel(product, 1e18, 0.02e18, "price0 * price1 should be ~1e36");
    }

    function test_getTWAP_getTWAP0_sameResult() public {
        _bootstrapOracle();
        vm.warp(block.timestamp + 1 hours);
        Pair(pair).sync();

        uint256 via_getTWAP  = oracle.getTWAP(pair);
        uint256 via_getTWAP0 = oracle.getTWAP0(pair);

        assertEq(via_getTWAP, via_getTWAP0, "getTWAP and getTWAP0 must return same value");
    }

    // -------------------------------------------------------
    // GET TWAP FOR TOKENS - ROUTING
    // -------------------------------------------------------

    function test_getTWAPForTokens_token0_returnsTWAP0() public {
        _bootstrapOracle();
        vm.warp(block.timestamp + 1 hours);
        Pair(pair).sync();

        address t0 = Pair(pair).token0();
        uint256 via_forTokens = oracle.getTWAPForTokens(pair, t0);
        uint256 via_getTWAP0  = oracle.getTWAP0(pair);

        assertEq(via_forTokens, via_getTWAP0, "getTWAPForTokens(token0) should equal getTWAP0");
    }

    function test_getTWAPForTokens_token1_returnsTWAP1() public {
        _bootstrapOracle();
        vm.warp(block.timestamp + 1 hours);
        Pair(pair).sync();

        address t1 = Pair(pair).token1();
        uint256 via_forTokens = oracle.getTWAPForTokens(pair, t1);
        uint256 via_getTWAP1  = oracle.getTWAP1(pair);

        assertEq(via_forTokens, via_getTWAP1, "getTWAPForTokens(token1) should equal getTWAP1");
    }

    function test_getTWAPForTokens_tokenA_correctDirection() public {
    _bootstrapOracle();
    vm.warp(block.timestamp + 1 hours);
    Pair(pair).sync();

    address t0 = Pair(pair).token0();
    (uint112 r0, uint112 r1,) = Pair(pair).getReserves();

    uint256 price = oracle.getTWAPForTokens(pair, address(tokenA));
    assertGt(price, 0, "price must be non-zero");

    // If tokenA == token0: TWAP0 = reserve1/reserve0 * 1e18
    // If tokenA == token1: TWAP1 = reserve0/reserve1 * 1e18
    uint256 expectedPrice = address(tokenA) == t0
        ? (uint256(r1) * 1e18) / uint256(r0)
        : (uint256(r0) * 1e18) / uint256(r1);

    assertApproxEqRel(price, expectedPrice, 0.02e18, "getTWAPForTokens direction wrong");
}

    // -------------------------------------------------------
    // TRANSFER OWNERSHIP
    // -------------------------------------------------------

    function test_transferOwnership_ownerCanTransfer() public {
        vm.prank(owner);
        oracle.transferOwnership(keeper);
        assertEq(oracle.owner(), keeper, "ownership not transferred");
    }

    function test_transferOwnership_oldOwnerLosesOnlyOwnerAccess() public {
        vm.prank(owner);
        oracle.transferOwnership(keeper);

        // Old owner can no longer call onlyOwner functions
        vm.prank(owner);
        vm.expectRevert(TWAPOracle.NotAuthorized.selector);
        oracle.transferOwnership(stranger);
    }

    function test_transferOwnership_newOwnerHasAccess() public {
        vm.prank(owner);
        oracle.transferOwnership(keeper);

        vm.prank(keeper);
        oracle.transferOwnership(stranger);
        assertEq(oracle.owner(), stranger, "new owner should have admin access");
    }

    function test_transferOwnership_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(TWAPOracle.ZeroAddress.selector);
        oracle.transferOwnership(address(0));
    }

    function test_transferOwnership_nonOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(TWAPOracle.NotAuthorized.selector);
        oracle.transferOwnership(stranger);
    }

    function test_transferOwnership_newOwnerCanUpdate() public {
        vm.prank(owner);
        oracle.transferOwnership(keeper);

        // New owner can update (anyone can, but testing ownership transfer)
        vm.prank(keeper);
        oracle.update(pair);

        (,, uint256 ts) = oracle.observations(pair);
        assertGt(ts, 0, "new owner should be able to update oracle");
    }

    // -------------------------------------------------------
    // MULTIPLE PAIRS
    // -------------------------------------------------------

    function test_multiplePairs_independentObservations() public {
        MockERC20 tokenC = new MockERC20("Token C", "TKC", 18);
        tokenC.mint(owner, 1_000_000 ether);

        address pair2 = factory.createPair(address(tokenA), address(tokenC));

        vm.startPrank(owner);
        tokenA.transfer(pair2, 100 ether);
        tokenC.transfer(pair2, 200 ether);
        Pair(pair2).mint(owner);
        vm.stopPrank();

        vm.prank(owner);
        oracle.update(pair);

        vm.warp(block.timestamp + 31 minutes);

        vm.prank(owner);
        oracle.update(pair2);

        // pair2 observation should be at later timestamp
        (,, uint256 ts1) = oracle.observations(pair);
        (,, uint256 ts2) = oracle.observations(pair2);

        assertGt(ts2, ts1, "pair2 should have later observation");

        // Advance more time and read both
        vm.warp(block.timestamp + 10 minutes);
        Pair(pair).sync();
        Pair(pair2).sync();

        uint256 price1 = oracle.getTWAP(pair);
        uint256 price2 = oracle.getTWAP(pair2);

        assertGt(price1, 0, "pair price zero");
        assertGt(price2, 0, "pair2 price zero");
    }

    // -------------------------------------------------------
    // FUZZ
    // -------------------------------------------------------

    function testFuzz_update_rateLimitAlwaysEnforced(uint256 waitSeconds) public {
        waitSeconds = bound(waitSeconds, 0, 2 hours - 1);

        vm.prank(owner);
        oracle.update(pair);

        vm.warp(block.timestamp + waitSeconds);

        vm.prank(owner);
        vm.expectRevert(TWAPOracle.UpdateTooSoon.selector);
        oracle.update(pair);
    }

    function testFuzz_getTWAP_alwaysNonZeroWithValidState(uint256 elapsed) public {
        elapsed = bound(elapsed, 30 minutes, 8 hours);

        vm.prank(owner);
        oracle.update(pair);

        uint256 warpTarget = block.timestamp + elapsed;
        vm.warp(warpTarget);
        Pair(pair).sync();

        uint256 price = oracle.getTWAP(pair);
        assertGt(price, 0, "TWAP should always be non-zero with valid state");
    }

    function testFuzz_getTWAP_alwaysRevertsWhenStale(uint256 extra) public {
        extra = bound(extra, 1, 30 days);

        _bootstrapOracle();
        vm.warp(block.timestamp + 8 hours + extra);

        vm.expectRevert(TWAPOracle.StalePrice.selector);
        oracle.getTWAP(pair);
    }
}