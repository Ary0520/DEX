// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20}      from "../mocks/MockERC20.sol";
import {ReentrantToken, ReturnFalseToken} from "../mocks/MaliciousTokens.sol";
import {Pair}           from "../../src/Pair.sol";
import {Factory}        from "../../src/FactoryContract.sol";

contract PairTest is Test {

    Factory   internal factory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address   internal pair;

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");
    address internal feeTo = makeAddr("feeTo");

    uint256 internal constant MIN_LIQ = 1000;

    function setUp() public {
        factory = new Factory();
        tokenA  = new MockERC20("Token A", "TKA", 18);
        tokenB  = new MockERC20("Token B", "TKB", 18);

        tokenA.mint(alice, 10_000_000 ether);
        tokenB.mint(alice, 10_000_000 ether);
        tokenA.mint(bob,   10_000_000 ether);
        tokenB.mint(bob,   10_000_000 ether);

        pair = factory.createPair(address(tokenA), address(tokenB));

        vm.label(pair,             "Pair");
        vm.label(address(factory), "Factory");
        vm.label(address(tokenA),  "TokenA");
        vm.label(address(tokenB),  "TokenB");
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    function _mint(address user, uint256 amtA, uint256 amtB)
        internal returns (uint256 liq)
    {
        vm.startPrank(user);
        tokenA.transfer(pair, amtA);
        tokenB.transfer(pair, amtB);
        liq = Pair(pair).mint(user);
        vm.stopPrank();
    }

    function _burn(address user, uint256 lpAmt)
        internal returns (uint256 a0, uint256 a1)
    {
        vm.startPrank(user);
        Pair(pair).transfer(pair, lpAmt);
        (a0, a1) = Pair(pair).burn(user);
        vm.stopPrank();
    }

    function _swapAForB(address user, uint256 amtIn)
        internal returns (uint256 amtOut)
    {
        (uint112 r0, uint112 r1,) = Pair(pair).getReserves();
        address t0 = Pair(pair).token0();

        (uint256 rIn, uint256 rOut) = address(tokenA) == t0
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));

        amtOut = (amtIn * 997 * rOut) / (rIn * 1000 + amtIn * 997);

        (uint256 out0, uint256 out1) = address(tokenA) == t0
            ? (uint256(0), amtOut)
            : (amtOut, uint256(0));

        vm.startPrank(user);
        tokenA.transfer(pair, amtIn);
        Pair(pair).swap(out0, out1, user);
        vm.stopPrank();
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) {
            z = 1;
        }
    }

    // -------------------------------------------------------
    // INITIALIZE
    // -------------------------------------------------------

    function test_initialize_onlyFactory_reverts() public {
    Pair rawPair = new Pair();
    // Call from a random address that is NOT the deployer (factory)
    vm.prank(alice);
    vm.expectRevert(Pair.Pair__Forbidden.selector);
    rawPair.initialize(address(tokenA), address(tokenB));
}

    function test_initialize_setsTokensCorrectly() public view {
        address t0 = Pair(pair).token0();
        address t1 = Pair(pair).token1();
        assertTrue(uint160(t0) < uint160(t1), "tokens not sorted");
        bool correct = (t0 == address(tokenA) && t1 == address(tokenB))
                    || (t0 == address(tokenB) && t1 == address(tokenA));
        assertTrue(correct, "wrong tokens stored");
    }

    function test_initialize_doubleInit_reverts() public {
        vm.prank(address(factory));
        vm.expectRevert(Pair.Pair__AlreadyInitialized.selector);
        Pair(pair).initialize(address(tokenA), address(tokenB));
    }

    function test_initialize_identicalTokens_reverts() public {
        vm.expectRevert(Factory.DEX__IdenticalTokens.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_initialize_zeroTokenA_reverts() public {
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.createPair(address(0), address(tokenB));
    }

    function test_initialize_zeroTokenB_reverts() public {
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.createPair(address(tokenA), address(0));
    }

    function test_initialize_duplicatePair_reverts() public {
        vm.expectRevert(Factory.DEX__PairAlreadyExists.selector);
        factory.createPair(address(tokenA), address(tokenB));
    }

    // -------------------------------------------------------
    // MINT - FIRST DEPOSIT
    // -------------------------------------------------------

    function test_mint_first_correctLPAmount() public {
        uint256 amtA     = 100 ether;
        uint256 amtB     = 100 ether;
        uint256 liq      = _mint(alice, amtA, amtB);
        uint256 expected = _sqrt(amtA * amtB) - MIN_LIQ;
        assertEq(liq, expected, "LP amount wrong on first deposit");
    }

    function test_mint_first_locksMinimumLiquidity() public {
        _mint(alice, 100 ether, 100 ether);
        assertEq(Pair(pair).balanceOf(address(1)), MIN_LIQ, "MINIMUM_LIQUIDITY not locked");
    }

    function test_mint_first_asymmetricRatio() public {
        uint256 amtA     = 1 ether;
        uint256 amtB     = 2000 ether;
        uint256 liq      = _mint(alice, amtA, amtB);
        uint256 expected = _sqrt(amtA * amtB) - MIN_LIQ;
        assertEq(liq, expected, "asymmetric first deposit LP wrong");
    }

    function test_mint_first_tooSmall_reverts() public {
        vm.startPrank(alice);
        tokenA.transfer(pair, 30);
        tokenB.transfer(pair, 30);
        vm.expectRevert(Pair.Pair__InsufficientLiquidityMinted.selector);
        Pair(pair).mint(alice);
        vm.stopPrank();
    }

    function test_mint_zeroTokenA_reverts() public {
        vm.startPrank(alice);
        tokenB.transfer(pair, 10 ether);
        vm.expectRevert(Pair.Pair__AmountMustBeMoreThanZero.selector);
        Pair(pair).mint(alice);
        vm.stopPrank();
    }

    function test_mint_zeroTokenB_reverts() public {
        vm.startPrank(alice);
        tokenA.transfer(pair, 10 ether);
        vm.expectRevert(Pair.Pair__AmountMustBeMoreThanZero.selector);
        Pair(pair).mint(alice);
        vm.stopPrank();
    }

    function test_mint_first_updatesReserves() public {
        _mint(alice, 100 ether, 200 ether);
        (uint112 r0, uint112 r1,) = Pair(pair).getReserves();
        assertEq(uint256(r0) + uint256(r1), 300 ether, "reserves wrong after first mint");
    }

    // -------------------------------------------------------
    // MINT - SUBSEQUENT DEPOSITS
    // -------------------------------------------------------

    function test_mint_subsequent_proportionalLP() public {
        _mint(alice, 100 ether, 100 ether);

        uint256 supplyBefore = Pair(pair).totalSupply();
        (uint112 r0, uint112 r1,) = Pair(pair).getReserves();

        uint256 amtA = 10 ether;
        uint256 amtB = 10 ether;
        uint256 liq  = _mint(bob, amtA, amtB);

        uint256 exp0     = (amtA * supplyBefore) / uint256(r0);
        uint256 exp1     = (amtB * supplyBefore) / uint256(r1);
        uint256 expected = exp0 < exp1 ? exp0 : exp1;

        assertEq(liq, expected, "subsequent LP wrong");
    }

    function test_mint_subsequent_imbalanced_takesMin() public {
        _mint(alice, 100 ether, 100 ether);
        uint256 liqBob = _mint(bob, 200 ether, 50 ether);
        assertTrue(liqBob > 0, "got zero LP on imbalanced deposit");
    }

    function test_mint_subsequent_totalSupplyIncreases() public {
        _mint(alice, 100 ether, 100 ether);
        uint256 supplyBefore = Pair(pair).totalSupply();
        _mint(bob, 10 ether, 10 ether);
        assertGt(Pair(pair).totalSupply(), supplyBefore, "total supply did not increase");
    }

    function test_mint_overflow_reverts() public {
        uint256 overflowAmt = uint256(type(uint112).max) + 1;
        tokenA.mint(alice, overflowAmt);
        tokenB.mint(alice, 1 ether);

        vm.startPrank(alice);
        tokenA.transfer(pair, overflowAmt);
        tokenB.transfer(pair, 1 ether);
        vm.expectRevert(Pair.Pair__Overflow.selector);
        Pair(pair).mint(alice);
        vm.stopPrank();
    }

    function test_mint_exactlyAtUint112Max_succeeds() public {
        // Test balance exactly at uint112.max boundary (should succeed)
        uint256 maxAmount = uint256(type(uint112).max);
        
        tokenA.mint(alice, maxAmount);
        tokenB.mint(alice, maxAmount);

        vm.startPrank(alice);
        tokenA.transfer(pair, maxAmount);
        tokenB.transfer(pair, maxAmount);
        
        // Should succeed - exactly at boundary is valid
        uint256 liq = Pair(pair).mint(alice);
        vm.stopPrank();

        assertGt(liq, 0, "should mint liquidity at uint112.max boundary");
        
        (uint112 r0, uint112 r1,) = Pair(pair).getReserves();
        assertEq(uint256(r0), maxAmount, "reserve0 should be at max");
        assertEq(uint256(r1), maxAmount, "reserve1 should be at max");
    }

    function test_swap_exactlyAtUint112Max_inputOverflows() public {
        // Reserves at uint112.max means any additional input token
        // will push balance over the limit — Pair correctly rejects it.
        uint256 maxAmount = uint256(type(uint112).max);

        tokenA.mint(alice, maxAmount);
        tokenB.mint(alice, maxAmount);

        vm.startPrank(alice);
        tokenA.transfer(pair, maxAmount);
        tokenB.transfer(pair, maxAmount);
        Pair(pair).mint(alice);
        vm.stopPrank();

        // Sending even 1 wei of tokenA makes balance0 = uint112.max + 1 → overflow
        tokenA.mint(bob, 1 ether);

        address t0 = Pair(pair).token0();
        bool aIsT0 = address(tokenA) == t0;

        vm.startPrank(bob);
        tokenA.transfer(pair, 1 ether);
        vm.expectRevert(Pair.Pair__Overflow.selector);
        if (aIsT0) {
            Pair(pair).swap(0, 0.99 ether, bob);
        } else {
            Pair(pair).swap(0.99 ether, 0, bob);
        }
        vm.stopPrank();
    }

    // -------------------------------------------------------
    // BURN
    // -------------------------------------------------------

    function test_burn_fullWithdrawal_returnsTokens() public {
        uint256 liq = _mint(alice, 100 ether, 200 ether);

        uint256 balABefore = tokenA.balanceOf(alice);
        uint256 balBBefore = tokenB.balanceOf(alice);

        (uint256 a0, uint256 a1) = _burn(alice, liq);

        assertTrue(a0 > 0 && a1 > 0, "burn returned zero tokens");
        assertEq(
            tokenA.balanceOf(alice) - balABefore + tokenB.balanceOf(alice) - balBBefore,
            a0 + a1,
            "balance change does not match returned amounts"
        );
    }

    function test_burn_proportionalReturn() public {
        _mint(alice, 100 ether, 100 ether);
        uint256 liqBob = _mint(bob, 50 ether, 50 ether);

        uint256 supplyBefore = Pair(pair).totalSupply();
        (uint112 r0, uint112 r1,) = Pair(pair).getReserves();

        uint256 expectedA = (liqBob * uint256(r0)) / supplyBefore;
        uint256 expectedB = (liqBob * uint256(r1)) / supplyBefore;

        address t0 = Pair(pair).token0();
        (uint256 expA, uint256 expB) = address(tokenA) == t0
            ? (expectedA, expectedB)
            : (expectedB, expectedA);

        uint256 beforeA = tokenA.balanceOf(bob);
        uint256 beforeB = tokenB.balanceOf(bob);

        _burn(bob, liqBob);

        assertApproxEqAbs(tokenA.balanceOf(bob) - beforeA, expA, 1, "tokenA return wrong");
        assertApproxEqAbs(tokenB.balanceOf(bob) - beforeB, expB, 1, "tokenB return wrong");
    }

    function test_burn_zeroLP_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        vm.prank(bob);
        vm.expectRevert(Pair.Pair__AmountZero.selector);
        Pair(pair).burn(bob);
    }

    function test_burn_aliceDoesNotAffectBobLP() public {
        _mint(alice, 100 ether, 100 ether);
        uint256 liqBob   = _mint(bob, 50 ether, 50 ether);
        uint256 liqAlice = Pair(pair).balanceOf(alice);

        _burn(alice, liqAlice);

        assertEq(Pair(pair).balanceOf(bob), liqBob, "Bob LP changed by Alice burn");
    }

    // -------------------------------------------------------
    // SWAP
    // -------------------------------------------------------

    function test_swap_tokenAForTokenB_correctOutput() public {
        _mint(alice, 1000 ether, 1000 ether);

        uint256 amtIn     = 10 ether;
        uint256 balBefore = tokenB.balanceOf(bob);

        _swapAForB(bob, amtIn);

        uint256 received = tokenB.balanceOf(bob) - balBefore;
        assertTrue(received > 0,     "swap produced zero output");
        assertGt(received, 9 ether,  "output suspiciously low");
        assertLt(received, 10 ether, "output exceeds input");
    }

    function test_swap_kNeverDecreases() public {
        _mint(alice, 1000 ether, 1000 ether);

        (uint112 r0b, uint112 r1b,) = Pair(pair).getReserves();
        uint256 kBefore = uint256(r0b) * uint256(r1b);

        _swapAForB(bob, 10 ether);

        (uint112 r0a, uint112 r1a,) = Pair(pair).getReserves();
        uint256 kAfter = uint256(r0a) * uint256(r1a);

        assertGe(kAfter, kBefore, "CRITICAL: k decreased after swap");
    }

    function test_swap_zeroOutput_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        vm.expectRevert(Pair.Pair__InsufficientOutputAmount.selector);
        Pair(pair).swap(0, 0, bob);
    }

    function test_swap_bothOutputs_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        vm.expectRevert(Pair.Pair__Forbidden.selector);
        Pair(pair).swap(1 ether, 1 ether, bob);
    }

    function test_swap_outputExceedsReserve0_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        (uint112 r0,,) = Pair(pair).getReserves();
        vm.expectRevert(Pair.Pair__Forbidden.selector);
        Pair(pair).swap(uint256(r0) + 1, 0, bob);
    }

    function test_swap_outputExceedsReserve1_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        (, uint112 r1,) = Pair(pair).getReserves();
        vm.expectRevert(Pair.Pair__Forbidden.selector);
        Pair(pair).swap(0, uint256(r1) + 1, bob);
    }

    function test_swap_toEqualsToken0_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        address t0 = Pair(pair).token0();

        vm.startPrank(bob);
        tokenA.transfer(pair, 1 ether);
        vm.expectRevert(Pair.Pair__InvalidAddress.selector);
        Pair(pair).swap(0, 0.9 ether, t0);
        vm.stopPrank();
    }

    function test_swap_toEqualsToken1_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        address t0 = Pair(pair).token0();
        address t1 = Pair(pair).token1();
        MockERC20 inputToken = address(tokenA) == t0 ? tokenA : tokenB;

        vm.startPrank(bob);
        inputToken.transfer(pair, 1 ether);
        vm.expectRevert(Pair.Pair__InvalidAddress.selector);
        Pair(pair).swap(0, 0.9 ether, t1);
        vm.stopPrank();
    }

    function test_swap_noInput_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        vm.expectRevert(Pair.Pair__AmountZero.selector);
        Pair(pair).swap(0, 1 ether, bob);
    }

    function test_swap_invariantViolation_reverts() public {
        _mint(alice, 100 ether, 100 ether);
        (, uint112 r1,) = Pair(pair).getReserves();
        address t0 = Pair(pair).token0();
        MockERC20 tokenIn = address(tokenA) == t0 ? tokenA : tokenB;

        vm.startPrank(bob);
        tokenIn.transfer(pair, 1);
        vm.expectRevert(Pair.Pair__InvariantViolation.selector);
        Pair(pair).swap(0, uint256(r1) / 2, bob);
        vm.stopPrank();
    }

    // -------------------------------------------------------
    // SKIM
    // -------------------------------------------------------

    function test_skim_removesExcessToRecipient() public {
        _mint(alice, 100 ether, 100 ether);
        tokenA.mint(pair, 50 ether);

        uint256 balBefore = tokenA.balanceOf(bob);
        Pair(pair).skim(bob);
        uint256 balAfter  = tokenA.balanceOf(bob);

        assertEq(balAfter - balBefore, 50 ether, "skim did not transfer excess");
    }

    function test_skim_doesNotChangeReserves() public {
        _mint(alice, 100 ether, 100 ether);
        tokenA.mint(pair, 50 ether);

        (uint112 r0Before, uint112 r1Before,) = Pair(pair).getReserves();
        Pair(pair).skim(bob);
        (uint112 r0After,  uint112 r1After,)  = Pair(pair).getReserves();

        assertEq(r0After, r0Before, "reserve0 changed after skim");
        assertEq(r1After, r1Before, "reserve1 changed after skim");
    }

    // -------------------------------------------------------
    // SYNC
    // -------------------------------------------------------

    function test_sync_updatesReserveToCurrentBalance() public {
        _mint(alice, 100 ether, 100 ether);
        tokenA.mint(pair, 50 ether);

        (uint112 r0Before,,) = Pair(pair).getReserves();
        Pair(pair).sync();
        (uint112 r0After,,)  = Pair(pair).getReserves();

        assertGt(uint256(r0After), uint256(r0Before), "sync did not update reserve");
        assertEq(uint256(r0After), tokenA.balanceOf(pair), "reserve does not match balance after sync");
    }

    // -------------------------------------------------------
    // TWAP ACCUMULATION
    // -------------------------------------------------------

    function test_twap_cumulativeIncreasesWithTime() public {
        _mint(alice, 100 ether, 200 ether);
        uint256 cum0Before = Pair(pair).price0CumulativeLast();

        vm.warp(block.timestamp + 1 hours);
        Pair(pair).sync();

        uint256 cum0After = Pair(pair).price0CumulativeLast();
        assertGt(cum0After, cum0Before, "cumulative price did not increase over time");
    }

    function test_twap_noAccumulationSameBlock() public {
        _mint(alice, 100 ether, 200 ether);
        uint256 cum0Before = Pair(pair).price0CumulativeLast();
        Pair(pair).sync();
        uint256 cum0After  = Pair(pair).price0CumulativeLast();
        assertEq(cum0After, cum0Before, "cumulative changed without time passing");
    }

    function test_twap_priceReflectsReserveRatio() public {
    _mint(alice, 100 ether, 400 ether);

    // Snapshot cumulative BEFORE warp
    uint256 cum0Before  = Pair(pair).price0CumulativeLast();

    // Use a fixed warp target so timeElapsed is unambiguous
    uint256 warpTo      = block.timestamp + 1 hours;
    uint256 timeElapsed = 1 hours;

    vm.warp(warpTo);
    Pair(pair).sync();

    uint256 cum0After = Pair(pair).price0CumulativeLast();

    assertGt(cum0After, cum0Before, "cumulative did not increase");

    uint256 avgPrice = (cum0After - cum0Before) / timeElapsed;
    assertGt(avgPrice, 0, "avgPrice is zero");

    // price0 in Pair._update = reserve1 * 1e18 / reserve0
    (uint112 r0, uint112 r1,) = Pair(pair).getReserves();
    uint256 expectedPrice = (uint256(r1) * 1e18) / uint256(r0);

    assertApproxEqRel(avgPrice, expectedPrice, 0.01e18, "TWAP ratio wrong");
}

    // -------------------------------------------------------
    // PROTOCOL FEE
    // -------------------------------------------------------

    function test_protocolFee_notCollected_whenFeeToZero() public {
        assertEq(factory.feeTo(), address(0));
        _mint(alice, 10000 ether, 10000 ether);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1);
            _swapAForB(bob, 100 ether);
        }

        _mint(bob, 1 ether, 1 ether);
        assertEq(Pair(pair).balanceOf(feeTo), 0, "fee collected when feeTo is address(0)");
    }

    function test_protocolFee_collected_whenFeeToSet() public {
        factory.setFeeTo(feeTo);
        _mint(alice, 10000 ether, 10000 ether);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1);
            _swapAForB(bob, 100 ether);
        }

        _mint(bob, 1 ether, 1 ether);
        assertGt(Pair(pair).balanceOf(feeTo), 0, "protocol fee not minted when feeTo is set");
    }

    function test_protocolFee_kLastZero_whenFeeToZero() public {
        _mint(alice, 100 ether, 100 ether);
        assertEq(Pair(pair).kLast(), 0, "kLast should be 0 when feeTo is address(0)");
    }

    function test_protocolFee_kLastSet_whenFeeToSet() public {
        factory.setFeeTo(feeTo);
        _mint(alice, 100 ether, 100 ether);
        assertGt(Pair(pair).kLast(), 0, "kLast should be set when feeTo is set");
    }

    function test_protocolFee_stateTransition_zeroToFeeTo() public {
        // Start with feeTo = address(0)
        assertEq(factory.feeTo(), address(0));
        
        _mint(alice, 10000 ether, 10000 ether);
        assertEq(Pair(pair).kLast(), 0, "kLast should be 0 initially");

        // Perform swaps to generate fees
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 1);
            _swapAForB(bob, 100 ether);
        }

        // Now enable protocol fee mid-operation
        factory.setFeeTo(feeTo);
        
        // Next mint should trigger protocol fee calculation
        uint256 feeToBalBefore = Pair(pair).balanceOf(feeTo);
        _mint(bob, 1 ether, 1 ether);
        
        // kLast should now be set
        assertGt(Pair(pair).kLast(), 0, "kLast should be set after feeTo enabled");
        
        // No protocol fee should be minted for the transition (kLast was 0)
        assertEq(Pair(pair).balanceOf(feeTo), feeToBalBefore, "no fee on first mint after enabling");
    }

    function test_protocolFee_stateTransition_feeToToZero() public {
        // Start with feeTo enabled
        factory.setFeeTo(feeTo);
        _mint(alice, 10000 ether, 10000 ether);
        
        uint256 kLastBefore = Pair(pair).kLast();
        assertGt(kLastBefore, 0, "kLast should be set initially");

        // Perform swaps to generate fees
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 1);
            _swapAForB(bob, 100 ether);
        }

        // Disable protocol fee
        factory.setFeeTo(address(0));
        
        // Next mint should clear kLast
        _mint(bob, 1 ether, 1 ether);
        
        assertEq(Pair(pair).kLast(), 0, "kLast should be cleared after feeTo disabled");
    }

    function test_protocolFee_stateTransition_feeToChange() public {
        // Start with feeTo enabled
        address feeTo1 = makeAddr("feeTo1");
        address feeTo2 = makeAddr("feeTo2");
        
        factory.setFeeTo(feeTo1);
        _mint(alice, 10000 ether, 10000 ether);

        // Perform swaps to generate fees
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1);
            _swapAForB(bob, 100 ether);
        }

        // Mint to collect fees to feeTo1
        _mint(bob, 1 ether, 1 ether);
        uint256 feeTo1Balance = Pair(pair).balanceOf(feeTo1);
        assertGt(feeTo1Balance, 0, "feeTo1 should receive protocol fees");

        // Change feeTo address
        factory.setFeeTo(feeTo2);

        // More swaps
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1);
            _swapAForB(bob, 100 ether);
        }

        // Mint should now send fees to feeTo2
        _mint(bob, 1 ether, 1 ether);
        
        assertGt(Pair(pair).balanceOf(feeTo2), 0, "feeTo2 should receive protocol fees");
        assertEq(Pair(pair).balanceOf(feeTo1), feeTo1Balance, "feeTo1 balance should not change");
    }

    function test_protocolFee_kLastBehavior_multipleTransitions() public {        // Test kLast through multiple state transitions
        _mint(alice, 10000 ether, 10000 ether);
        
        // 1. Start: feeTo = 0, kLast = 0
        assertEq(Pair(pair).kLast(), 0);
        
        // 2. Enable feeTo
        factory.setFeeTo(feeTo);
        _mint(bob, 1 ether, 1 ether);
        uint256 kLast1 = Pair(pair).kLast();
        assertGt(kLast1, 0, "kLast should be set");
        
        // 3. Disable feeTo
        factory.setFeeTo(address(0));
        _mint(bob, 1 ether, 1 ether);
        assertEq(Pair(pair).kLast(), 0, "kLast should be cleared");
        
        // 4. Re-enable feeTo
        factory.setFeeTo(feeTo);
        _mint(bob, 1 ether, 1 ether);
        uint256 kLast2 = Pair(pair).kLast();
        assertGt(kLast2, 0, "kLast should be set again");
        
        // kLast values should be different due to different reserve states
        assertNotEq(kLast1, kLast2, "kLast should reflect current reserves");
    }

    function test_protocolFee_rootKNotGreater_noFeesMinted() public {
        // _mintProtocolFee branch: kLast != 0 but rootK <= rootKLast
        // This happens when reserves decrease (e.g. after a burn with no swaps)
        factory.setFeeTo(feeTo);
        _mint(alice, 10000 ether, 10000 ether);

        // kLast is now set
        assertGt(Pair(pair).kLast(), 0);

        // Burn some liquidity — reduces reserves, so rootK < rootKLast
        uint256 liqAlice = Pair(pair).balanceOf(alice);
        _burn(alice, liqAlice / 2);

        uint256 feeToBalBefore = Pair(pair).balanceOf(feeTo);

        // Next mint triggers _mintProtocolFee with kLast set but rootK <= rootKLast
        // No protocol fee should be minted
        _mint(bob, 1 ether, 1 ether);

        assertEq(Pair(pair).balanceOf(feeTo), feeToBalBefore, "no fee when rootK did not grow");
    }

    function test_burn_kLastUpdated_whenFeeOn() public {
        // burn() feeOn branch: kLast updated after burn when feeTo is set
        factory.setFeeTo(feeTo);
        _mint(alice, 100 ether, 100 ether);

        uint256 liq = Pair(pair).balanceOf(alice);
        _burn(alice, liq / 2);

        // kLast should be updated after burn when feeTo != address(0)
        assertGt(Pair(pair).kLast(), 0, "kLast should be set after burn with feeOn");
    }

    function test_burn_kLastNotUpdated_whenFeeOff() public {
        // burn() feeOn = false branch: kLast stays 0 when feeTo is address(0)
        assertEq(factory.feeTo(), address(0));
        _mint(alice, 100 ether, 100 ether);

        uint256 liq = Pair(pair).balanceOf(alice);
        _burn(alice, liq / 2);

        assertEq(Pair(pair).kLast(), 0, "kLast should stay 0 when feeOff");
    }

    function test_safeTransfer_failureReverts() public {
        // _safeTransfer failure branch via ReturnFalseToken
        ReturnFalseToken badToken = new ReturnFalseToken();
        MockERC20 tB2 = new MockERC20("B2", "B2", 18);

        badToken.mint(alice, 1_000_000 ether);
        tB2.mint(alice, 1_000_000 ether);

        address badPair = factory.createPair(address(badToken), address(tB2));

        vm.startPrank(alice);
        badToken.transfer(badPair, 10_000 ether);
        tB2.transfer(badPair, 10_000 ether);
        Pair(badPair).mint(alice);
        vm.stopPrank();

        // Swap should fail because badToken.transfer returns false
        tB2.mint(bob, 1 ether);
        vm.startPrank(bob);
        tB2.transfer(badPair, 1 ether);
        address t0 = Pair(badPair).token0();
        bool badIsT0 = address(badToken) == t0;
        vm.expectRevert(Pair.Pair__TransferFailed.selector);
        if (badIsT0) {
            Pair(badPair).swap(0.9 ether, 0, bob);
        } else {
            Pair(badPair).swap(0, 0.9 ether, bob);
        }
        vm.stopPrank();
    }

    // -------------------------------------------------------
    // REENTRANCY
    // -------------------------------------------------------

    function test_reentrancy_mintIsLocked() public {
        ReentrantToken rToken = new ReentrantToken();
        MockERC20 tB2 = new MockERC20("B2", "B2", 18);

        rToken.mint(alice, 1_000_000 ether);
        tB2.mint(alice, 1_000_000 ether);

        address rPair = factory.createPair(address(rToken), address(tB2));

        bytes memory reentrantCall = abi.encodeWithSelector(Pair.mint.selector, alice);
        rToken.arm(rPair, reentrantCall);

        vm.startPrank(alice);
        rToken.transfer(rPair, 10 ether);
        tB2.transfer(rPair, 10 ether);
        Pair(rPair).mint(alice);
        vm.stopPrank();

        assertGt(Pair(rPair).balanceOf(alice), 0, "legitimate mint failed");
    }

    function test_reentrancy_swapIsLocked() public {
        ReentrantToken rToken = new ReentrantToken();
        MockERC20 tB2 = new MockERC20("B2", "B2", 18);

        rToken.mint(alice, 1_000_000 ether);
        tB2.mint(alice, 1_000_000 ether);

        address rPair = factory.createPair(address(rToken), address(tB2));

        vm.startPrank(alice);
        rToken.transfer(rPair, 100 ether);
        tB2.transfer(rPair, 100 ether);
        Pair(rPair).mint(alice);
        vm.stopPrank();

        address t0   = Pair(rPair).token0();
        bool rIsT0   = address(rToken) == t0;
        bytes memory reentrantCall = abi.encodeWithSelector(
            Pair.swap.selector,
            rIsT0 ? uint256(0) : uint256(1 ether),
            rIsT0 ? uint256(1 ether) : uint256(0),
            alice
        );
        rToken.arm(rPair, reentrantCall);

        rToken.mint(alice, 2 ether);
        vm.startPrank(alice);
        rToken.transfer(rPair, 1 ether);
        (uint256 out0, uint256 out1) = rIsT0
            ? (uint256(0), uint256(0.9 ether))
            : (uint256(0.9 ether), uint256(0));
        Pair(rPair).swap(out0, out1, alice);
        vm.stopPrank();
    }

    // -------------------------------------------------------
    // FUZZ
    // -------------------------------------------------------

    function testFuzz_swap_kNeverDecreases(
        uint128 seedA,
        uint128 seedB,
        uint128 swapAmt
    ) public {
        uint256 amtA = bound(uint256(seedA), 1_000 ether, 500_000 ether);
        uint256 amtB = bound(uint256(seedB), 1_000 ether, 500_000 ether);
        uint256 sIn  = bound(uint256(swapAmt), 1 ether, amtA / 4);

        tokenA.mint(alice, amtA);
        tokenB.mint(alice, amtB);
        _mint(alice, amtA, amtB);

        (uint112 r0b, uint112 r1b,) = Pair(pair).getReserves();
        uint256 kBefore = uint256(r0b) * uint256(r1b);

        tokenA.mint(bob, sIn);
        _swapAForB(bob, sIn);

        (uint112 r0a, uint112 r1a,) = Pair(pair).getReserves();
        uint256 kAfter = uint256(r0a) * uint256(r1a);

        assertGe(kAfter, kBefore, "CRITICAL: k invariant broken");
    }

    function testFuzz_burn_neverReturnMoreThanDeposited(
        uint128 seedA,
        uint128 seedB
    ) public {
        uint256 amtA = bound(uint256(seedA), 2_000 ether, 500_000 ether);
        uint256 amtB = bound(uint256(seedB), 2_000 ether, 500_000 ether);

        tokenA.mint(alice, amtA);
        tokenB.mint(alice, amtB);

        uint256 liq = _mint(alice, amtA, amtB);

        uint256 balABefore = tokenA.balanceOf(alice);
        uint256 balBBefore = tokenB.balanceOf(alice);

        _burn(alice, liq);

        uint256 gotA = tokenA.balanceOf(alice) - balABefore;
        uint256 gotB = tokenB.balanceOf(alice) - balBBefore;

        assertTrue(gotA > 0 && gotB > 0, "got nothing from burn");
        assertLe(gotA, amtA, "got back more tokenA than deposited");
        assertLe(gotB, amtB, "got back more tokenB than deposited");
    }

    function testFuzz_mint_lpProportional(
        uint128 seed1A, uint128 seed1B,
        uint128 seed2A, uint128 seed2B
    ) public {
        uint256 a1 = bound(uint256(seed1A), 1_000 ether, 100_000 ether);
        uint256 b1 = bound(uint256(seed1B), 1_000 ether, 100_000 ether);
        uint256 a2 = bound(uint256(seed2A), 100 ether,   10_000 ether);
        uint256 b2 = bound(uint256(seed2B), 100 ether,   10_000 ether);

        tokenA.mint(alice, a1);
        tokenB.mint(alice, b1);
        tokenA.mint(bob,   a2);
        tokenB.mint(bob,   b2);

        _mint(alice, a1, b1);
        uint256 supplyBefore = Pair(pair).totalSupply();

        uint256 liq2 = _mint(bob, a2, b2);

        assertGt(liq2, 0, "second mint returned zero LP");
        assertGt(Pair(pair).totalSupply(), supplyBefore, "total supply did not increase");
    }
}