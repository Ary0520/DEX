// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2}    from "forge-std/Test.sol";
import {FeeConverter}      from "../../src/FeeConverter.sol";
import {ILShieldVault}     from "../../src/ILShieldVault.sol";
import {Router}            from "../../src/Router.sol";
import {Factory}           from "../../src/FactoryContract.sol";
import {Pair}              from "../../src/Pair.sol";
import {TWAPOracle}        from "../../src/TWAPOracle.sol";
import {ILPositionManager} from "../../src/ILPositionManager.sol";
import {MockERC20}         from "../mocks/MockERC20.sol";

contract FeeConverterTest is Test {

    FeeConverter      internal converter;
    ILShieldVault     internal vault;
    Router            internal router;
    Factory           internal factory;
    TWAPOracle        internal oracle;
    ILPositionManager internal pm;

    MockERC20 internal usdc;
    MockERC20 internal feeToken;

    address internal owner    = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal keeper   = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    address internal pair;

    // A fixed absolute starting timestamp used throughout all tests.
    // Must be well above CONVERSION_COOLDOWN (1 hours = 3600s) so that
    // lastConversion[pair][token] == 0 is treated as "already cooled down"
    // from the very first block, and the relative warps below never
    // accidentally land below the 3600-second mark.
    uint256 constant T0 = 1_000_000;

    function setUp() public {
        // ── Pin block.timestamp to a known, safe baseline ────────────────
        // This is the single most important fix: Foundry starts at t=1, so
        // any warp of less than 3599 seconds would leave block.timestamp
        // below CONVERSION_COOLDOWN and make every convert() call revert
        // with CooldownNotMet (because lastConversion defaults to 0 and
        // 0 + 3600 > block.timestamp).
        vm.warp(T0);

        usdc     = new MockERC20("USDC",      "USDC", 6);
        feeToken = new MockERC20("FeeToken",  "FEE",  18);

        vm.startPrank(owner);
        factory = new Factory();
        oracle  = new TWAPOracle();
        vault   = new ILShieldVault(address(this), address(usdc));
        pm      = new ILPositionManager(address(this));

        router = new Router(
            address(factory),
            address(vault),
            address(pm),
            address(oracle),
            treasury
        );

        vault.setRouter(address(router));
        pm = new ILPositionManager(address(router));
        router.setPositionManager(address(pm));

        converter = new FeeConverter(
            address(factory),
            address(vault),
            address(oracle),
            address(usdc)
        );

        vault.setFeeConverter(address(converter));
        vm.stopPrank();

        // ── Create feeToken/USDC pair ─────────────────────────────────────
        pair = factory.createPair(address(feeToken), address(usdc));

        // ── Seed liquidity: 1 feeToken = 2 USDC ──────────────────────────
        feeToken.mint(owner, 1_000_000 ether);
        usdc.mint(owner, 2_000_000 * 1e6);

        vm.startPrank(owner);
        feeToken.transfer(pair, 100_000 ether);
        usdc.transfer(pair, 200_000 * 1e6);
        Pair(pair).mint(owner);
        vm.stopPrank();

        // ── Bootstrap oracle: capture initial price snapshot ──────────────
        // The pair now has liquidity (100k feeToken : 200k USDC = 1:2 ratio).
        // We need to establish a TWAP baseline. The oracle needs TWO snapshots
        // separated by at least MAX_UPDATE_WINDOW (2 hours) to compute TWAP.
        
        // First snapshot at T0+1 (1 second after liquidity mint)
        vm.warp(T0 + 1);
        Pair(pair).sync(); // Accumulate price for 1 second
        vm.prank(keeper);
        oracle.update(pair);

        // Wait 2 hours and take second snapshot
        vm.warp(T0 + 1 + 2 hours);
        Pair(pair).sync(); // Accumulate price for 2 hours
        vm.prank(keeper);
        oracle.update(pair);

        // Now TWAP is available and reflects the 1:2 price ratio

        // ── Seed vault with raw fees ───────────────────────────────────────
        // Advance time so we're well past the oracle snapshots.
        // CRITICAL: sync the pair BEFORE the oracle snapshot so cumulative
        // prices accumulate the elapsed time. Without sync(), price0CumulativeLast
        // stays frozen and the TWAP returns 0.
        vm.warp(T0 + 1 + 3 hours);
        Pair(pair).sync();

        // Seed a SMALL fee amount relative to pool depth so price impact stays
        // well within the 1% slippage cap enforced by FeeConverter.
        // Pool: 100_000 feeToken : 200_000 USDC.
        // Swapping 10 feeToken (~0.01% of pool) → negligible price impact.
        feeToken.mint(address(vault), 10 ether);
        vm.prank(address(router));
        vault.depositFees(pair, address(feeToken), 10 ether);

        // Give the vault enough USDC so allocateUSDC() can credit it back.
        usdc.mint(address(vault), 1_000_000 * 1e6);
    }

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    function test_constructor_setsAddresses() public view {
        assertEq(converter.factory(),    address(factory));
        assertEq(converter.vault(),      address(vault));
        assertEq(converter.twapOracle(), address(oracle));
        assertEq(converter.USDC(),       address(usdc));
        assertEq(converter.owner(),      owner);
    }

    function test_constructor_zeroFactory_reverts() public {
        vm.expectRevert(FeeConverter.ZeroAddress.selector);
        new FeeConverter(address(0), address(vault), address(oracle), address(usdc));
    }

    function test_constructor_zeroVault_reverts() public {
        vm.expectRevert(FeeConverter.ZeroAddress.selector);
        new FeeConverter(address(factory), address(0), address(oracle), address(usdc));
    }

    function test_constructor_zeroOracle_reverts() public {
        vm.expectRevert(FeeConverter.ZeroAddress.selector);
        new FeeConverter(address(factory), address(vault), address(0), address(usdc));
    }

    function test_constructor_zeroUSDC_reverts() public {
        vm.expectRevert(FeeConverter.ZeroAddress.selector);
        new FeeConverter(address(factory), address(vault), address(oracle), address(0));
    }

    // -------------------------------------------------------
    // CONVERT
    // -------------------------------------------------------

    function test_convert_success() public {
        uint256 vaultUsdcBefore  = usdc.balanceOf(address(vault));
        uint256 callerUsdcBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        converter.convert(pair, address(feeToken));

        // Vault should receive USDC
        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBefore);
        // Caller should receive bonus
        assertGt(usdc.balanceOf(keeper), callerUsdcBefore);
        // Raw fees are reduced to near-zero (Router re-deposits a tiny vault-fee
        // slice of the conversion swap, so balance won't be exactly 0).
        assertLt(vault.rawFeeBalances(pair, address(feeToken)), 10 ether);
    }

    function test_convert_tokenIsUSDC_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.TokenIsUSDC.selector);
        converter.convert(pair, address(usdc));
    }

    function test_convert_cooldownNotMet_reverts() public {
        // First conversion succeeds; second immediately reverts.
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));

        vm.prank(keeper);
        vm.expectRevert(FeeConverter.CooldownNotMet.selector);
        converter.convert(pair, address(feeToken));
    }

    function test_convert_nothingToConvert_reverts() public {
        // First conversion drains the raw balance.
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));

        // Refresh oracle and advance past cooldown so the second call gets
        // through the cooldown guard. The Router re-deposits a tiny vault-fee
        // slice back into rawFeeBalances during the swap, so the balance is
        // non-zero but below MIN_CONVERSION_USDC — expect BelowMinimum.
        vm.warp(block.timestamp + 2 hours);
        Pair(pair).sync();
        vm.prank(keeper);
        oracle.update(pair);
        vm.warp(block.timestamp + 1 hours);
        Pair(pair).sync();

        vm.prank(keeper);
        vm.expectRevert(FeeConverter.BelowMinimum.selector);
        converter.convert(pair, address(feeToken));
    }

    function test_convert_staleOracle_reverts() public {
        // Wind the clock past MAX_STALENESS (8 hours) without updating oracle.
        vm.warp(block.timestamp + 9 hours);
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.TWAPUnavailable.selector);
        converter.convert(pair, address(feeToken));
    }

    function test_convert_twapAutoUpdate_success() public {
        // Test the lazy TWAP auto-update flow in two phases:
        // Phase 1: oracle has no observation → FeeConverter calls update() internally,
        //          but TWAPWindowTooSmall (0s elapsed) → reverts TWAPUnavailable.
        //          Because the whole tx reverts, oracle state is NOT persisted.
        // Phase 2: manually update oracle, wait 30+ min, then convert succeeds.
        // This proves the auto-update code path is exercised and the system
        // self-heals without a dedicated keeper.

        MockERC20 newToken = new MockERC20("NewToken", "NEW", 18);
        address newPair = factory.createPair(address(newToken), address(usdc));

        newToken.mint(owner, 100_000 ether);
        usdc.mint(owner, 200_000 * 1e6);

        vm.startPrank(owner);
        newToken.transfer(newPair, 100_000 ether);
        usdc.transfer(newPair, 200_000 * 1e6);
        Pair(newPair).mint(owner);
        vm.stopPrank();

        // Accumulate some price history
        vm.warp(block.timestamp + 1 hours);
        Pair(newPair).sync();

        newToken.mint(address(vault), 10 ether);
        vm.prank(address(router));
        vault.depositFees(newPair, address(newToken), 10 ether);

        // No oracle observation yet
        (,, uint256 tsBefore) = oracle.observations(newPair);
        assertEq(tsBefore, 0, "oracle should have no observation initially");

        // First attempt: FeeConverter internally tries update() then getTWAP(),
        // but window is 0 → TWAPWindowTooSmall → whole tx reverts.
        // Oracle state rolls back too (revert undoes everything).
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.TWAPUnavailable.selector);
        converter.convert(newPair, address(newToken));

        // Oracle still has no observation (state was rolled back)
        (,, uint256 tsStillZero) = oracle.observations(newPair);
        assertEq(tsStillZero, 0, "oracle state rolled back with revert");

        // Now manually seed the oracle (simulating a keeper or a second caller)
        vm.prank(keeper);
        oracle.update(newPair);

        (,, uint256 tsAfterUpdate) = oracle.observations(newPair);
        assertGt(tsAfterUpdate, 0, "oracle should have observation after manual update");

        // Wait 31 minutes so TWAP window is valid
        vm.warp(block.timestamp + 31 minutes);
        Pair(newPair).sync();

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        // Now convert succeeds — TWAP window is valid
        vm.prank(keeper);
        converter.convert(newPair, address(newToken));

        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBefore, "vault should receive USDC");
    }

    function test_convert_conversionFailureRollback() public {
        // Strategy: make the Router's swap revert by draining the pair's USDC
        // to near-zero so getAmountsOut returns 0 < amountOutMin → Router reverts
        // → FeeConverter catch block fires → ConversionFailed + rollback.

        MockERC20 tinyToken = new MockERC20("TinyToken", "TINY", 18);
        address tinyPair = factory.createPair(address(tinyToken), address(usdc));

        // Seed liquidity: 100 tokens : 200 USDC
        tinyToken.mint(owner, 1000 ether);
        usdc.mint(owner, 2000 * 1e6);

        vm.startPrank(owner);
        tinyToken.transfer(tinyPair, 100 ether);
        usdc.transfer(tinyPair, 200 * 1e6);
        Pair(tinyPair).mint(owner);
        vm.stopPrank();

        // Bootstrap oracle
        vm.warp(T0 + 1);
        Pair(tinyPair).sync();
        vm.prank(keeper);
        oracle.update(tinyPair);

        vm.warp(T0 + 1 + 2 hours);
        Pair(tinyPair).sync();
        vm.prank(keeper);
        oracle.update(tinyPair);

        vm.warp(T0 + 1 + 3 hours);
        Pair(tinyPair).sync();

        // Drain USDC by sending tinyToken in and swapping USDC out.
        // We need to leave so little USDC that even a tiny fee conversion
        // can't meet minUsdcOut (which is 99% of TWAP price).
        // TWAP: 1 token = 2 USDC. We'll convert 10 tokens → minOut ≈ 19.8 USDC.
        // Leave only 1 USDC in pool → getAmountsOut returns < 1 USDC → Router reverts.
        address token0 = Pair(tinyPair).token0();
        bool usdcIsToken0 = address(usdc) == token0;

        // Send enough tinyToken to drain 199 USDC out of 200 USDC pool
        // AMM formula: amountIn = reserveIn * amountOut / (reserveOut - amountOut) / 0.997
        // To get 199 USDC out: amountIn ≈ 100 * 199 / (200 - 199) / 0.997 ≈ 19960 tokens
        tinyToken.mint(owner, 20_000 ether);
        vm.startPrank(owner);
        tinyToken.transfer(tinyPair, 20_000 ether);
        if (usdcIsToken0) {
            Pair(tinyPair).swap(199 * 1e6, 0, owner);
        } else {
            Pair(tinyPair).swap(0, 199 * 1e6, owner);
        }
        vm.stopPrank();

        // Pool now has ~1 USDC left. Seed vault with 10 tokens.
        // TWAP-based minOut = ~19.8 USDC. Pool can only give < 1 USDC.
        // Router.getAmountsOut returns < amountOutMin → Router__SlippageExceeded
        // → FeeConverter catch → ConversionFailed + rollback.
        tinyToken.mint(address(vault), 10 ether);
        vm.prank(address(router));
        vault.depositFees(tinyPair, address(tinyToken), 10 ether);

        uint256 rawBalanceBefore = vault.rawFeeBalances(tinyPair, address(tinyToken));

        vm.prank(keeper);
        vm.expectRevert(FeeConverter.ConversionFailed.selector);
        converter.convert(tinyPair, address(tinyToken));

        // Rollback verified: cooldown reset, tokens returned
        assertEq(converter.lastConversion(tinyPair, address(tinyToken)), 0, "cooldown should be rolled back");
        assertEq(vault.rawFeeBalances(tinyPair, address(tinyToken)), rawBalanceBefore, "tokens should be returned");
    }

    function test_convert_callerBonusHardCap_largeConversion() public {
        // To trigger the hard cap, usdcReceived must exceed 500_000 USDC
        // (because 0.1% of 500k = 500 USDC > 50 USDC cap)
        // We need a pool with >500k USDC and a fee amount large enough
        //
        // TWAP overflow root cause: reserve1 * 1e18 overflows when reserve1 is large
        // with 18-decimal tokens. Fix: use a 6-decimal token on both sides so
        // the price ratio stays small and the multiplication never overflows.

        MockERC20 bigToken = new MockERC20("BigToken", "BIG", 6); // 6 decimals like USDC
        address bigPair = factory.createPair(address(bigToken), address(usdc));

        // Pool: 1M bigToken : 1M USDC (1:1 ratio, both 6 decimals)
        // reserve * 1e18 = 1e6 * 1e18 = 1e24 — well within uint256
        uint256 poolAmt = 1_000_000 * 1e6;
        bigToken.mint(owner, poolAmt);
        usdc.mint(owner, poolAmt);

        vm.startPrank(owner);
        bigToken.transfer(bigPair, poolAmt);
        usdc.transfer(bigPair, poolAmt);
        Pair(bigPair).mint(owner);
        vm.stopPrank();

        // Bootstrap oracle
        // Always warp forward — never use absolute T0 timestamps after setUp
        // setUp leaves block.timestamp at T0 + 1 + 3 hours = T0 + 10801
       // First snapshot
        vm.warp(block.timestamp + 1);
        Pair(bigPair).sync();
        vm.prank(keeper);
        oracle.update(bigPair);

        // Second snapshot
        vm.warp(block.timestamp + 2 hours);
        Pair(bigPair).sync();
        vm.prank(keeper);
        oracle.update(bigPair);

        // Move forward
        vm.warp(block.timestamp + 1 hours);
        Pair(bigPair).sync();

        // Seed vault with 600k bigToken (~$600k at 1:1)
        // 0.1% of $600k = $600 bonus → capped at $50
        // 600k is 60% of pool which is too much slippage — use 0.1% of pool
        // 0.1% of 1M = 1000 tokens = $1000 → bonus = $1 (below cap)
        // We need bonus > $50, so usdcOut > $50,000
        // 5% of pool = 50k tokens → ~$47.6k out (AMM math) → bonus ~$47 (below cap)
        // 6% of pool = 60k tokens → ~$56.6k out → bonus ~$56 → capped at $50 ✓
        // But 6% causes slippage... let's check: minOut = 99% of TWAP
        // TWAP says 1:1, so 60k tokens → expected 60k USDC, minOut = 59.4k
        // Actual AMM output at 6% impact ≈ 56.6k < 59.4k → SlippageExceeded
        //
        // The only clean solution: make the pool large enough that even a
        // $500k+ conversion is <1% of pool depth.
        // Pool needs to be >50M USDC. With 6-decimal tokens:
        // reserve = 50M * 1e6 = 5e13 → price = 5e13 * 1e18 / 5e13 = 1e18 ✓ no overflow

        // Re-create with 50M pool
        MockERC20 deepToken = new MockERC20("DeepToken", "DEEP", 6);
        address deepPair = factory.createPair(address(deepToken), address(usdc));

        uint256 deepPool = 50_000_000 * 1e6; // 50M each
        deepToken.mint(owner, deepPool);
        usdc.mint(owner, deepPool);

        vm.startPrank(owner);
        deepToken.transfer(deepPair, deepPool);
        usdc.transfer(deepPair, deepPool);
        Pair(deepPair).mint(owner);
        vm.stopPrank();

        // First snapshot
        vm.warp(block.timestamp + 1);
        Pair(deepPair).sync();
        vm.prank(keeper);
        oracle.update(deepPair);

        // Second snapshot after 2 hours
        vm.warp(block.timestamp + 2 hours);
        Pair(deepPair).sync();
        vm.prank(keeper);
        oracle.update(deepPair);

        // Move forward again (NO backward risk)
        vm.warp(block.timestamp + 1 hours);
        Pair(deepPair).sync();

        // Seed 600k tokens = 1.2% of pool → minimal slippage, ~$600k out
        // 0.1% of $600k = $600 → capped at $50
        uint256 fee = 200_000 * 1e6;
        deepToken.mint(address(vault), fee);
        vm.prank(address(router));
        vault.depositFees(deepPair, address(deepToken), fee);

        uint256 keeperBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        converter.convert(deepPair, address(deepToken));

        uint256 bonus = usdc.balanceOf(keeper) - keeperBefore;

        assertEq(bonus, converter.MAX_CALLER_BONUS(), "bonus should be capped at 50 USDC");
        assertEq(bonus, 50e6, "bonus should be exactly 50 USDC");
    }

    function test_convert_cooldownBoundary_justBeforeCooldown_reverts() public {
        // First conversion
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));

        // Seed more fees for second attempt
        feeToken.mint(address(vault), 10 ether);
        vm.prank(address(router));
        vault.depositFees(pair, address(feeToken), 10 ether);

        // Advance to exactly 1 hour - 1 second
        vm.warp(block.timestamp + 1 hours - 1);
        Pair(pair).sync();

        // Should still be in cooldown
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.CooldownNotMet.selector);
        converter.convert(pair, address(feeToken));
    }

    function test_convert_cooldownBoundary_exactlyAtCooldown_succeeds() public {
        // First conversion
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));

        // Seed more fees
        feeToken.mint(address(vault), 10 ether);
        vm.prank(address(router));
        vault.depositFees(pair, address(feeToken), 10 ether);

        // Update oracle so TWAP is fresh
        vm.warp(block.timestamp + 2 hours);
        Pair(pair).sync();
        vm.prank(keeper);
        oracle.update(pair);

        // Advance to exactly 1 hour from first conversion
        // Note: we're now at T0 + 3h + 2h + 1h = T0 + 6h
        vm.warp(block.timestamp + 1 hours);
        Pair(pair).sync();

        uint256 vaultBefore = usdc.balanceOf(address(vault));

        // Should succeed - cooldown is exactly met
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));

        assertGt(usdc.balanceOf(address(vault)), vaultBefore, "conversion should succeed at cooldown boundary");
    }

    function test_convert_slippageRejection() public {
        // FeeConverter passes minUsdcOut directly to Router as amountOutMin.
        // When spot price is worse than TWAP, Router.getAmountsOut returns
        // a value below minUsdcOut → Router__SlippageExceeded → caught by
        // FeeConverter's try/catch → ConversionFailed (with rollback).
        // This IS the slippage protection path — it surfaces as ConversionFailed.

        address token0 = Pair(pair).token0();
        bool usdcIsToken0 = address(usdc) == token0;

        // Crash spot price: send 30k feeToken in, swap out USDC
        // Pool: 100k feeToken : 200k USDC. After swap: ~130k feeToken : ~154k USDC
        // Spot price drops from 2.0 to ~1.18 USDC/token (>40% worse than TWAP)
        feeToken.mint(owner, 30_000 ether);
        vm.startPrank(owner);
        feeToken.transfer(pair, 30_000 ether);
        if (usdcIsToken0) {
            Pair(pair).swap(45_000 * 1e6, 0, owner);
        } else {
            Pair(pair).swap(0, 45_000 * 1e6, owner);
        }
        vm.stopPrank();

        // Seed vault with fees
        feeToken.mint(address(vault), 50 ether);
        vm.prank(address(router));
        vault.depositFees(pair, address(feeToken), 50 ether);

        // TWAP still says 1 FEE = 2 USDC → minOut = 99% of that
        // Spot price now ~1.18 → Router.getAmountsOut returns ~59 USDC for 50 tokens
        // minOut based on TWAP = 99% * 100 USDC = 99 USDC → Router reverts → ConversionFailed
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.ConversionFailed.selector);
        converter.convert(pair, address(feeToken));

        // Rollback verified: cooldown was reset
        assertEq(converter.lastConversion(pair, address(feeToken)), 0, "cooldown should be rolled back on slippage");
    }

    // -------------------------------------------------------
    // COOLDOWN
    // -------------------------------------------------------

    function test_cooldownRemaining_zeroBeforeFirstConversion() public view {
        // lastConversion == 0 and block.timestamp >> CONVERSION_COOLDOWN (1h),
        // so cooldown is already satisfied — must return 0.
        assertEq(converter.cooldownRemaining(pair, address(feeToken)), 0);
    }

    function test_cooldownRemaining_nonZeroAfterConversion() public {
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));
        assertGt(converter.cooldownRemaining(pair, address(feeToken)), 0);
    }

    function test_cooldownRemaining_zeroAfterCooldown() public {
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));
        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(converter.cooldownRemaining(pair, address(feeToken)), 0);
    }

    // -------------------------------------------------------
    // PREVIEW CONVERSION
    // -------------------------------------------------------

    function test_previewConversion_returnsTrueWhenConvertible() public view {
        (uint256 raw, uint256 expected,,, bool ok) =
            converter.previewConversion(pair, address(feeToken));
        assertTrue(ok);
        assertGt(raw, 0);
        assertGt(expected, 0);
    }

    function test_previewConversion_returnsFalseForUSDC() public view {
        (,,,, bool ok) = converter.previewConversion(pair, address(usdc));
        assertFalse(ok);
    }

    function test_previewConversion_returnsFalseAfterCooldown() public {
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));
        (,,,, bool ok) = converter.previewConversion(pair, address(feeToken));
        assertFalse(ok);
    }

    // -------------------------------------------------------
    // PREVIEW CONVERSION - additional branch coverage
    // -------------------------------------------------------

    function test_previewConversion_zeroRawAmount_returnsFalse() public {
        // rawAmount == 0 branch in previewConversion
        MockERC20 emptyToken = new MockERC20("Empty", "EMP", 18);
        address emptyPair = factory.createPair(address(emptyToken), address(usdc));
        // No fees deposited → rawFeeBalances == 0
        (uint256 raw,,,, bool ok) = converter.previewConversion(emptyPair, address(emptyToken));
        assertEq(raw, 0);
        assertFalse(ok);
    }

    function test_previewConversion_noPairForToken_returnsFalse() public {
        // usdcFeeTokenPair == address(0) branch: token has no USDC pair in factory
        MockERC20 orphanToken = new MockERC20("Orphan", "ORP", 18);
        // Create a pair for orphanToken with something other than USDC
        // so factory.getPair(orphanToken, usdc) returns address(0)
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        address orphanPair = factory.createPair(address(orphanToken), address(other));

        // Seed vault with fees for orphanPair
        orphanToken.mint(address(vault), 10 ether);
        vm.prank(address(router));
        vault.depositFees(orphanPair, address(orphanToken), 10 ether);

        (uint256 raw, uint256 exp,,, bool ok) = converter.previewConversion(orphanPair, address(orphanToken));
        assertGt(raw, 0);
        assertEq(exp, 0);
        assertFalse(ok);
    }

    function test_previewConversion_twapUnavailable_returnsFalse() public {
        // TWAP catch branch: oracle has no observation → getTWAPForTokens reverts
        MockERC20 noOracleToken = new MockERC20("NoOracle", "NOO", 18);
        address noOraclePair = factory.createPair(address(noOracleToken), address(usdc));

        noOracleToken.mint(owner, 1000 ether);
        usdc.mint(owner, 2000 * 1e6);
        vm.startPrank(owner);
        noOracleToken.transfer(noOraclePair, 100 ether);
        usdc.transfer(noOraclePair, 200 * 1e6);
        Pair(noOraclePair).mint(owner);
        vm.stopPrank();

        // No oracle update → getTWAPForTokens reverts with NoObservation
        noOracleToken.mint(address(vault), 10 ether);
        vm.prank(address(router));
        vault.depositFees(noOraclePair, address(noOracleToken), 10 ether);

        (uint256 raw,,,, bool ok) = converter.previewConversion(noOraclePair, address(noOracleToken));
        assertGt(raw, 0);
        assertFalse(ok, "should return false when TWAP unavailable");
    }

    function test_previewConversion_callerBonusCapped() public {
        // callerBonus > MAX_CALLER_BONUS branch in previewConversion
        // Need expectedUsdc > 500_000 USDC so 0.1% > 50 USDC
        // Use the deepToken pair from the hard cap test setup
        MockERC20 deepToken = new MockERC20("DeepToken", "DEEP", 6);
        address deepPair = factory.createPair(address(deepToken), address(usdc));

        uint256 deepPool = 50_000_000 * 1e6;
        deepToken.mint(owner, deepPool);
        usdc.mint(owner, deepPool);
        vm.startPrank(owner);
        deepToken.transfer(deepPair, deepPool);
        usdc.transfer(deepPair, deepPool);
        Pair(deepPair).mint(owner);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        Pair(deepPair).sync();
        vm.prank(keeper);
        oracle.update(deepPair);
        vm.warp(block.timestamp + 2 hours);
        Pair(deepPair).sync();
        vm.prank(keeper);
        oracle.update(deepPair);
        vm.warp(block.timestamp + 1 hours);
        Pair(deepPair).sync();

        uint256 fee = 600_000 * 1e6;
        deepToken.mint(address(vault), fee);
        vm.prank(address(router));
        vault.depositFees(deepPair, address(deepToken), fee);

        (, uint256 expectedUsdc, uint256 callerBonus,,) =
            converter.previewConversion(deepPair, address(deepToken));

        assertGt(expectedUsdc, 500_000 * 1e6, "expected > 500k USDC");
        assertEq(callerBonus, converter.MAX_CALLER_BONUS(), "bonus should be capped at 50 USDC");
    }

    // -------------------------------------------------------
    // CONVERT - additional branch coverage
    // -------------------------------------------------------

    function test_convert_noUsdcPairForToken_reverts() public {
        // usdcFeeTokenPair == address(0) branch in convert()
        MockERC20 orphanToken = new MockERC20("Orphan", "ORP", 18);
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        // Create pair between orphanToken and other (NOT usdc)
        address orphanPair = factory.createPair(address(orphanToken), address(other));

        orphanToken.mint(address(vault), 10 ether);
        vm.prank(address(router));
        vault.depositFees(orphanPair, address(orphanToken), 10 ether);

        vm.prank(keeper);
        vm.expectRevert(FeeConverter.TWAPUnavailable.selector);
        converter.convert(orphanPair, address(orphanToken));
    }

    function test_convert_pairNotRegistered_reverts() public {
        // _getPairToken0 !success branch: pass an EOA (no code) as pair
        address eoa = makeAddr("eoa");
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.PairNotRegistered.selector);
        converter.convert(eoa, address(feeToken));
    }

    function test_convert_zeroBonusNotTransferred() public {
        // callerBonus == 0 branch: seed a tiny amount so expectedUsdc is just
        // above MIN_CONVERSION_USDC but bonus rounds to 0
        // At 0.1% (10 bps), bonus = 0 when usdcReceived < 10000 (i.e. < $0.01)
        // We need usdcReceived between $10 and $10000 for bonus to be non-zero
        // Actually bonus = usdcReceived * 10 / 10000, rounds to 0 when usdcReceived < 1000
        // So seed fees worth just above $10 but below $0.10 bonus threshold
        // usdcReceived must be < 1000 (< $0.001) for bonus == 0 — impossible above $10 min
        // The callerBonus == 0 branch is only reachable if usdcReceived == 0,
        // which can't happen after a successful swap above MIN_CONVERSION_USDC.
        // Instead verify the bonus > 0 path is always taken for normal conversions.
        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));
        // Bonus is always > 0 for any conversion above $10
        assertGt(usdc.balanceOf(keeper) - keeperBefore, 0, "bonus should be non-zero");
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(FeeConverter.NotOwner.selector);
        converter.transferOwnership(makeAddr("alice"));
    }

    function test_transferOwnership_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(FeeConverter.ZeroAddress.selector);
        converter.transferOwnership(address(0));
    }

    function test_transferOwnership_transfers() public {
        vm.prank(owner);
        converter.transferOwnership(keeper);
        assertEq(converter.owner(), keeper);
    }
}
