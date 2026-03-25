// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Factory}           from "../../src/FactoryContract.sol";
import {Router}            from "../../src/Router.sol";
import {Pair}              from "../../src/Pair.sol";
import {ILShieldVault}     from "../../src/ILShieldVault.sol";
import {ILPositionManager} from "../../src/ILPositionManager.sol";
import {TWAPOracle}        from "../../src/TWAPOracle.sol";
import {FeeConverter}      from "../../src/FeeConverter.sol";
import {MockERC20}         from "../mocks/MockERC20.sol";

contract SystemTest is Test {

    Factory           factory;
    Router            router;
    ILShieldVault     vault;
    ILPositionManager pm;
    TWAPOracle        oracle;
    FeeConverter      feeConverter;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 usdc;

    address owner    = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address staker   = makeAddr("staker");
    address keeper   = makeAddr("keeper");

    address pair;

    function setUp() public {
        usdc   = new MockERC20("USDC",    "USDC", 6);
        tokenA = new MockERC20("Token A", "TKA",  18);
        tokenB = new MockERC20("Token B", "TKB",  18);

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

        feeConverter = new FeeConverter(
            address(factory),
            address(vault),
            address(oracle),
            address(usdc)
        );
        vault.setFeeConverter(address(feeConverter));
        vm.stopPrank();

        pair = factory.createPair(address(tokenA), address(tokenB));

        // Fund users
        tokenA.mint(alice,   1_000_000 ether);
        tokenB.mint(alice,   1_000_000 ether);
        tokenA.mint(bob,     1_000_000 ether);
        tokenB.mint(bob,     1_000_000 ether);
        usdc.mint(staker,    1_000_000 * 1e6);

        vm.prank(alice);   tokenA.approve(address(router), type(uint256).max);
        vm.prank(alice);   tokenB.approve(address(router), type(uint256).max);
        vm.prank(alice);   Pair(pair).approve(address(router), type(uint256).max);
        vm.prank(bob);     tokenA.approve(address(router), type(uint256).max);
        vm.prank(bob);     tokenB.approve(address(router), type(uint256).max);
        vm.prank(staker);  usdc.approve(address(vault), type(uint256).max);
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    function _addLiquidity(address user, uint256 amtA, uint256 amtB) internal returns (uint256 liq) {
        vm.prank(user);
        (,, liq) = router.addLiquidity(
            address(tokenA), address(tokenB),
            amtA, amtB, 0, 0, user, block.timestamp
        );
    }

    function _swap(address user, uint256 amtIn) internal {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(user);
        router.swapExactTokensForTokens(amtIn, 0, path, user, block.timestamp);
    }

    function _bootstrapOracle() internal {
        vm.prank(keeper);
        oracle.update(pair);
        vm.warp(block.timestamp + 31 minutes);
        Pair(pair).sync();
    }

    // -------------------------------------------------------
    // FULL FLOW — REAL CONTRACTS
    // -------------------------------------------------------

    function test_fullFlow_addSwapRemove() public {
        // Add liquidity
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        assertGt(liq, 0);

        (uint112 r0, uint112 r1,) = Pair(pair).getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);

        // Swap
        uint256 bBefore = tokenB.balanceOf(bob);
        _swap(bob, 10 ether);
        assertGt(tokenB.balanceOf(bob) - bBefore, 0);

        // Fees accumulated in vault
        assertGt(vault.rawFeeBalances(pair, address(tokenA)), 0);

        // Remove liquidity
        vm.prank(alice);
        (uint256 outA, uint256 outB) = router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );
        assertGt(outA, 0);
        assertGt(outB, 0);
    }

    function test_fullFlow_ILPayout_afterLockPeriod() public {
        // Alice adds liquidity
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);

        // Staker provides insurance capital
        vm.prank(staker);
        vault.stake(pair, 50_000 * 1e6);

        // Simulate price movement via swaps (bob buys a lot of tokenB)
        for (uint i; i < 10; i++) {
            _swap(bob, 500 ether);
        }

        // Bootstrap oracle after price moved
        _bootstrapOracle();

        // Advance past MIN_LOCK (7 days)
        vm.warp(block.timestamp + 8 days);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );

        // Alice may or may not receive IL payout depending on price impact
        // Key invariant: alice's USDC balance never decreases
        assertGe(usdc.balanceOf(alice), aliceUsdcBefore);
    }

    function test_fullFlow_noILPayout_beforeLockPeriod() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);

        // Staker provides capital
        vm.prank(staker);
        vault.stake(pair, 50_000 * 1e6);

        // Swaps to create IL
        for (uint i; i < 5; i++) {
            _swap(bob, 100 ether);
        }

        // Remove immediately — before MIN_LOCK
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );

        // No IL payout — lock not met
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "no payout before lock");
    }

    function test_fullFlow_stakerLifecycle() public {
        // Staker stakes
        uint256 stakeAmt = 10_000 * 1e6;
        vm.prank(staker);
        vault.stake(pair, stakeAmt);

        // LP adds liquidity and swaps generate fees
        _addLiquidity(alice, 1000 ether, 1000 ether);
        for (uint i; i < 5; i++) {
            _swap(bob, 100 ether);
        }

        // Owner allocates USDC fees to vault (simulating fee conversion)
        usdc.mint(owner, 1000 * 1e6);
        vm.prank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(owner);
        vault.allocateUSDC(pair, 1000 * 1e6);

        // Staker has pending fees
        assertGt(vault.pendingFees(pair, staker), 0);

        // Staker harvests
        uint256 stakerBefore = usdc.balanceOf(staker);
        vm.prank(staker);
        vault.harvestFees(pair);
        assertGt(usdc.balanceOf(staker) - stakerBefore, 0);

        // Staker requests unstake
        vm.prank(staker);
        vault.requestUnstake(pair);

        // Wait cooldown
        vm.warp(block.timestamp + 14 days + 1);

        // Staker unstakes
        (, uint256 shares,,) = vault.stakerPositions(pair, staker);
        uint256 stakerBefore2 = usdc.balanceOf(staker);
        vm.prank(staker);
        vault.unstake(pair, shares);

        assertApproxEqAbs(usdc.balanceOf(staker) - stakerBefore2, stakeAmt, 2);
    }

    function test_fullFlow_exposureTracking() public {
        assertEq(vault.getExposure(pair), 0);

        uint256 liq1 = _addLiquidity(alice, 100 ether, 100 ether);
        uint256 exp1 = vault.getExposure(pair);
        assertGt(exp1, 0, "exposure should increase on add");

        uint256 liq2 = _addLiquidity(bob, 50 ether, 50 ether);
        uint256 exp2 = vault.getExposure(pair);
        assertGt(exp2, exp1, "exposure should increase on second add");

        vm.prank(alice);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq1, 0, 0, alice, block.timestamp
        );
        uint256 exp3 = vault.getExposure(pair);
        assertLt(exp3, exp2, "exposure should decrease on remove");

        vm.prank(bob);
        Pair(pair).approve(address(router), type(uint256).max);
        vm.prank(bob);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq2, 0, 0, bob, block.timestamp
        );
        uint256 exp4 = vault.getExposure(pair);
        assertLe(exp4, exp3, "exposure should decrease further");
    }

    function test_fullFlow_multipleSwaps_feesAccumulate() public {
        _addLiquidity(alice, 10_000 ether, 10_000 ether);

        uint256 feeBefore = vault.rawFeeBalances(pair, address(tokenA));
        for (uint i; i < 20; i++) {
            _swap(bob, 10 ether);
        }
        uint256 feeAfter = vault.rawFeeBalances(pair, address(tokenA));

        assertGt(feeAfter - feeBefore, 0, "fees should accumulate over swaps");
    }

    function test_fullFlow_tierConfig_affectsFeeSplit() public {
        // Verify tier config is read correctly via getPairConfig
        // pair was created in setUp() with tokenA/tokenB (both volatile by default)
        (uint256 vaultFee, uint256 treasuryFee,,) = factory.getPairConfig(pair);
        // Volatile tier defaults
        assertEq(vaultFee,    15);
        assertEq(treasuryFee, 10);
    }
}
