// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2}      from "forge-std/Test.sol";
import {Router}              from "../../src/Router.sol";
import {Factory}             from "../../src/FactoryContract.sol";
import {Pair}                from "../../src/Pair.sol";
import {ILShieldVault}       from "../../src/ILShieldVault.sol";
import {ILPositionManager}   from "../../src/ILPositionManager.sol";
import {TWAPOracle}          from "../../src/TWAPOracle.sol";
import {MockERC20}           from "../mocks/MockERC20.sol";

contract RouterTest is Test {

    Router            internal router;
    Factory           internal factory;
    ILShieldVault     internal vault;
    ILPositionManager internal pm;
    TWAPOracle        internal oracle;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal usdc;

    address internal owner    = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    address internal pair;

    function setUp() public {
        usdc   = new MockERC20("USDC", "USDC", 6);
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        vm.startPrank(owner);
        factory = new Factory();
        oracle  = new TWAPOracle();
        vault   = new ILShieldVault(address(this), address(usdc)); // temp router
        pm      = new ILPositionManager(address(this));            // temp router

        router = new Router(
            address(factory),
            address(vault),
            address(pm),
            address(oracle),
            treasury
        );

        vault.setRouter(address(router));
        // redeploy pm with correct router
        pm = new ILPositionManager(address(router));
        router.setPositionManager(address(pm));
        vm.stopPrank();

        // Create pair
        pair = factory.createPair(address(tokenA), address(tokenB));

        // Fund users
        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(alice, 1_000_000 ether);
        tokenA.mint(bob,   1_000_000 ether);
        tokenB.mint(bob,   1_000_000 ether);

        vm.prank(alice);
        tokenA.approve(address(router), type(uint256).max);
        vm.prank(alice);
        tokenB.approve(address(router), type(uint256).max);
        vm.prank(alice);
        Pair(pair).approve(address(router), type(uint256).max);

        vm.prank(bob);
        tokenA.approve(address(router), type(uint256).max);
        vm.prank(bob);
        tokenB.approve(address(router), type(uint256).max);
        vm.prank(bob);
        Pair(pair).approve(address(router), type(uint256).max);
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    function _addLiquidity(address user, uint256 amtA, uint256 amtB)
        internal returns (uint256 liq)
    {
        vm.prank(user);
        (,, liq) = router.addLiquidity(
            address(tokenA), address(tokenB),
            amtA, amtB, 0, 0,
            user, block.timestamp
        );
    }

    function _swap(address user, uint256 amtIn) internal returns (uint256 amtOut) {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(user);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amtIn, 0, path, user, block.timestamp
        );
        amtOut = amounts[1];
    }

    function _bootstrapOracle() internal {
        vm.prank(owner);
        oracle.update(pair);
        vm.warp(block.timestamp + 6 minutes);
        Pair(pair).sync();
    }

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    function test_constructor_setsAddresses() public view {
        assertEq(router.factory(),         address(factory));
        assertEq(router.ilVault(),         address(vault));
        assertEq(router.positionManager(), address(pm));
        assertEq(router.twapOracle(),      address(oracle));
        assertEq(router.treasury(),        treasury);
        assertEq(router.owner(),           owner);
    }

    function test_constructor_zeroFactory_reverts() public {
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        new Router(address(0), address(vault), address(pm), address(oracle), treasury);
    }

    function test_constructor_zeroVault_reverts() public {
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        new Router(address(factory), address(0), address(pm), address(oracle), treasury);
    }

    function test_constructor_zeroPM_reverts() public {
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        new Router(address(factory), address(vault), address(0), address(oracle), treasury);
    }

    function test_constructor_zeroOracle_reverts() public {
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        new Router(address(factory), address(vault), address(pm), address(0), treasury);
    }

    function test_constructor_zeroTreasury_reverts() public {
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        new Router(address(factory), address(vault), address(pm), address(oracle), address(0));
    }

    // -------------------------------------------------------
    // ADD LIQUIDITY
    // -------------------------------------------------------

    function test_addLiquidity_firstDeposit_setsReserves() public {
        _addLiquidity(alice, 100 ether, 200 ether);
        (uint112 r0, uint112 r1,) = Pair(pair).getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    function test_addLiquidity_returnsLPTokens() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        assertGt(liq, 0);
        assertEq(Pair(pair).balanceOf(alice), liq);
    }

    function test_addLiquidity_zeroTo_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB),
            100 ether, 100 ether, 0, 0,
            address(0), block.timestamp
        );
    }

    function test_addLiquidity_expired_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Router.Router__Expired.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB),
            100 ether, 100 ether, 0, 0,
            alice, block.timestamp - 1
        );
    }

    function test_addLiquidity_slippageA_reverts() public {
        _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(bob);
        vm.expectRevert(Router.Router__SlippageExceeded.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB),
            10 ether, 10 ether,
            999 ether, 0,   // amountAMin way too high
            bob, block.timestamp
        );
    }

    function test_addLiquidity_slippageB_reverts() public {
        _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(bob);
        vm.expectRevert(Router.Router__SlippageExceeded.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB),
            10 ether, 10 ether,
            0, 999 ether,   // amountBMin way too high
            bob, block.timestamp
        );
    }

    function test_addLiquidity_recordsPosition() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        ILPositionManager.Position memory pos = pm.getPosition(pair, alice);
        assertEq(pos.liquidity, liq);
        assertGt(pos.valueAtDeposit, 0);
        assertEq(pos.timestamp, block.timestamp);
    }

    function test_addLiquidity_updatesExposure() public {
        _addLiquidity(alice, 100 ether, 100 ether);
        assertGt(vault.getExposure(pair), 0);
    }

    function test_addLiquidity_createsPairIfNotExists() public {
        MockERC20 tC = new MockERC20("C", "C", 18);
        MockERC20 tD = new MockERC20("D", "D", 18);
        tC.mint(alice, 1000 ether);
        tD.mint(alice, 1000 ether);
        vm.prank(alice); tC.approve(address(router), type(uint256).max);
        vm.prank(alice); tD.approve(address(router), type(uint256).max);

        assertEq(factory.getPair(address(tC), address(tD)), address(0));

        vm.prank(alice);
        router.addLiquidity(address(tC), address(tD), 100 ether, 100 ether, 0, 0, alice, block.timestamp);

        assertTrue(factory.getPair(address(tC), address(tD)) != address(0));
    }

    function test_addLiquidity_emitsEvent() public {
        vm.expectEmit(false, true, false, false);
        emit Router.LiquidityAdded(pair, alice, 0);
        _addLiquidity(alice, 100 ether, 100 ether);
    }

    // -------------------------------------------------------
    // REMOVE LIQUIDITY
    // -------------------------------------------------------

    function test_removeLiquidity_returnsTokens() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        uint256 balABefore = tokenA.balanceOf(alice);
        uint256 balBBefore = tokenB.balanceOf(alice);

        vm.prank(alice);
        (uint256 amtA, uint256 amtB) = router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );

        assertGt(amtA, 0);
        assertGt(amtB, 0);
        assertEq(tokenA.balanceOf(alice) - balABefore, amtA);
        assertEq(tokenB.balanceOf(alice) - balBBefore, amtB);
    }

    function test_removeLiquidity_zeroLiquidity_reverts() public {
        _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert(Router.Router__AmountZero.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            0, 0, 0, alice, block.timestamp
        );
    }

    function test_removeLiquidity_zeroTo_reverts() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, address(0), block.timestamp
        );
    }

    function test_removeLiquidity_expired_reverts() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert(Router.Router__Expired.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp - 1
        );
    }

    function test_removeLiquidity_pairNotFound_reverts() public {
        MockERC20 tX = new MockERC20("X", "X", 18);
        vm.prank(alice);
        vm.expectRevert(Router.Router__PairNotFound.selector);
        router.removeLiquidity(
            address(tokenA), address(tX),
            1 ether, 0, 0, alice, block.timestamp
        );
    }

    function test_removeLiquidity_slippageA_reverts() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert(Router.Router__SlippageExceeded.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 999 ether, 0, alice, block.timestamp
        );
    }

    function test_removeLiquidity_slippageB_reverts() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert(Router.Router__SlippageExceeded.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 999 ether, alice, block.timestamp
        );
    }

    function test_removeLiquidity_noILPayout_beforeMinLock() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 200 ether);
        // No time passes — below MIN_LOCK
        uint256 vaultBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );
        // No USDC payout since vault has no funds and lock not met
        assertEq(usdc.balanceOf(alice), vaultBefore);
    }

    function test_removeLiquidity_reducesExposure() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        uint256 exposureBefore = vault.getExposure(pair);
        assertGt(exposureBefore, 0);

        vm.prank(alice);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );

        assertLt(vault.getExposure(pair), exposureBefore);
    }

    function test_removeLiquidity_reducesPosition() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(alice);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );
        ILPositionManager.Position memory pos = pm.getPosition(pair, alice);
        assertEq(pos.liquidity, 0);
    }

    function test_removeLiquidity_partial_reducesPositionProportionally() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        vm.prank(alice);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq / 2, 0, 0, alice, block.timestamp
        );
        ILPositionManager.Position memory pos = pm.getPosition(pair, alice);
        assertApproxEqAbs(pos.liquidity, liq / 2, 1);
    }

    function test_removeLiquidity_emitsEvent() public {
        uint256 liq = _addLiquidity(alice, 100 ether, 100 ether);
        vm.expectEmit(false, true, false, false);
        emit Router.LiquidityRemoved(pair, alice, 0, 0, 0);
        vm.prank(alice);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );
    }

    // -------------------------------------------------------
    // SWAP
    // -------------------------------------------------------

    function test_swap_producesOutput() public {
        _addLiquidity(alice, 1000 ether, 1000 ether);
        uint256 before = tokenB.balanceOf(bob);
        _swap(bob, 10 ether);
        assertGt(tokenB.balanceOf(bob) - before, 0);
    }

    function test_swap_zeroAmountIn_reverts() public {
        _addLiquidity(alice, 1000 ether, 1000 ether);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(bob);
        vm.expectRevert(Router.Router__AmountZero.selector);
        router.swapExactTokensForTokens(0, 0, path, bob, block.timestamp);
    }

    function test_swap_shortPath_reverts() public {
        address[] memory path = new address[](1);
        path[0] = address(tokenA);
        vm.prank(bob);
        vm.expectRevert(Router.Router__InvalidPath.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, block.timestamp);
    }

    function test_swap_zeroTo_reverts() public {
        _addLiquidity(alice, 1000 ether, 1000 ether);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(bob);
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, address(0), block.timestamp);
    }

    function test_swap_expired_reverts() public {
        _addLiquidity(alice, 1000 ether, 1000 ether);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(bob);
        vm.expectRevert(Router.Router__Expired.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, block.timestamp - 1);
    }

    function test_swap_pairNotFound_reverts() public {
        MockERC20 tX = new MockERC20("X", "X", 18);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tX);
        vm.prank(bob);
        vm.expectRevert(Router.Router__PairNotFound.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, block.timestamp);
    }

    function test_swap_slippage_reverts() public {
        _addLiquidity(alice, 1000 ether, 1000 ether);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(bob);
        vm.expectRevert(Router.Router__SlippageExceeded.selector);
        router.swapExactTokensForTokens(1 ether, 999 ether, path, bob, block.timestamp);
    }

    function test_swap_vaultFeeDeducted() public {
        _addLiquidity(alice, 1000 ether, 1000 ether);
        uint256 amtIn = 100 ether;

        // Volatile tier: vaultFeeBps = 15 (0.15%)
        uint256 expectedVaultFee = (amtIn * 15) / 10000;

        uint256 rawBefore = vault.rawFeeBalances(pair, address(tokenA));
        _swap(bob, amtIn);
        uint256 rawAfter = vault.rawFeeBalances(pair, address(tokenA));

        assertEq(rawAfter - rawBefore, expectedVaultFee, "vault fee wrong");
    }

    function test_swap_treasuryFeeDeducted() public {
        _addLiquidity(alice, 1000 ether, 1000 ether);
        uint256 amtIn = 100 ether;

        // Volatile tier: treasuryFeeBps = 10 (0.10%)
        uint256 expectedTreasuryFee = (amtIn * 10) / 10000;

        uint256 before = tokenA.balanceOf(treasury);
        _swap(bob, amtIn);
        assertEq(tokenA.balanceOf(treasury) - before, expectedTreasuryFee, "treasury fee wrong");
    }

    function test_swap_emitsEvent() public {
        _addLiquidity(alice, 1000 ether, 1000 ether);
        vm.expectEmit(false, true, false, false);
        emit Router.SwapExecuted(pair, bob, 0, 0);
        _swap(bob, 10 ether);
    }

    // -------------------------------------------------------
    // GET AMOUNTS OUT
    // -------------------------------------------------------

    function test_getAmountsOut_correctOutput() public {
        _addLiquidity(alice, 1000 ether, 2000 ether);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory amounts = router.getAmountsOut(10 ether, path);
        assertEq(amounts[0], 10 ether);
        assertGt(amounts[1], 0);
        assertLt(amounts[1], 20 ether); // can't get more than reserve ratio
    }

    function test_getAmountsOut_pairNotFound_reverts() public {
        MockERC20 tX = new MockERC20("X", "X", 18);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tX);
        vm.expectRevert(Router.Router__PairNotFound.selector);
        router.getAmountsOut(1 ether, path);
    }

    // -------------------------------------------------------
    // QUOTE
    // -------------------------------------------------------

    function test_quote_correctRatio() public view {
        uint256 result = router.quote(100 ether, 1000 ether, 2000 ether);
        assertEq(result, 200 ether);
    }

    function test_quote_zeroReserveA_reverts() public {
        vm.expectRevert(Router.Router__PairNotFound.selector);
        router.quote(100 ether, 0, 1000 ether);
    }

    function test_quote_zeroReserveB_reverts() public {
        vm.expectRevert(Router.Router__PairNotFound.selector);
        router.quote(100 ether, 1000 ether, 0);
    }

    // -------------------------------------------------------
    // ADMIN
    // -------------------------------------------------------

    function test_setILVault_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Router.Router__NotOwner.selector);
        router.setILVault(makeAddr("v"));
    }

    function test_setILVault_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        router.setILVault(address(0));
    }

    function test_setILVault_updates() public {
        address newVault = makeAddr("newVault");
        vm.prank(owner); router.setILVault(newVault);
        assertEq(router.ilVault(), newVault);
    }

    function test_setPositionManager_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Router.Router__NotOwner.selector);
        router.setPositionManager(makeAddr("pm"));
    }

    function test_setPositionManager_updates() public {
        address newPm = makeAddr("newPm");
        vm.prank(owner); router.setPositionManager(newPm);
        assertEq(router.positionManager(), newPm);
    }

    function test_setTWAPOracle_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Router.Router__NotOwner.selector);
        router.setTWAPOracle(makeAddr("oracle"));
    }

    function test_setTWAPOracle_updates() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(owner); router.setTWAPOracle(newOracle);
        assertEq(router.twapOracle(), newOracle);
    }

    function test_setTreasury_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Router.Router__NotOwner.selector);
        router.setTreasury(makeAddr("t"));
    }

    function test_setTreasury_updates() public {
        address newT = makeAddr("newT");
        vm.prank(owner); router.setTreasury(newT);
        assertEq(router.treasury(), newT);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Router.Router__NotOwner.selector);
        router.transferOwnership(alice);
    }

    function test_transferOwnership_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        router.transferOwnership(address(0));
    }

    function test_transferOwnership_transfers() public {
        vm.prank(owner); router.transferOwnership(alice);
        assertEq(router.owner(), alice);
    }

    // -------------------------------------------------------
    // FUZZ
    // -------------------------------------------------------

    function testFuzz_swap_outputNeverExceedsReserve(uint256 amtIn) public {
        _addLiquidity(alice, 100_000 ether, 100_000 ether);
        amtIn = bound(amtIn, 0.001 ether, 1000 ether);
        tokenA.mint(bob, amtIn);

        (uint112 r0, uint112 r1,) = Pair(pair).getReserves();
        address t0 = Pair(pair).token0();
        uint256 reserveOut = address(tokenA) == t0 ? uint256(r1) : uint256(r0);

        uint256 before = tokenB.balanceOf(bob);
        _swap(bob, amtIn);
        uint256 received = tokenB.balanceOf(bob) - before;

        assertLt(received, reserveOut, "output must not exceed reserve");
    }

    function testFuzz_addRemoveLiquidity_noValueLeak(uint256 amtA, uint256 amtB) public {
        amtA = bound(amtA, 1 ether, 10_000 ether);
        amtB = bound(amtB, 1 ether, 10_000 ether);

        uint256 balABefore = tokenA.balanceOf(alice);
        uint256 balBBefore = tokenB.balanceOf(alice);

        uint256 liq = _addLiquidity(alice, amtA, amtB);

        vm.prank(alice);
        (uint256 outA, uint256 outB) = router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, block.timestamp
        );

        // Should get back close to what was deposited (minus MINIMUM_LIQUIDITY on first deposit)
        assertLe(balABefore - tokenA.balanceOf(alice), amtA);
        assertLe(balBBefore - tokenB.balanceOf(alice), amtB);
        assertGt(outA, 0);
        assertGt(outB, 0);
    }

    function testFuzz_feeSplit_sumCorrect(uint256 amtIn) public {
        _addLiquidity(alice, 100_000 ether, 100_000 ether);
        amtIn = bound(amtIn, 1 ether, 1000 ether);
        tokenA.mint(bob, amtIn);

        uint256 vaultBefore    = vault.rawFeeBalances(pair, address(tokenA));
        uint256 treasuryBefore = tokenA.balanceOf(treasury);
        uint256 bobBefore      = tokenA.balanceOf(bob);

        _swap(bob, amtIn);

        uint256 vaultFee    = vault.rawFeeBalances(pair, address(tokenA)) - vaultBefore;
        uint256 treasuryFee = tokenA.balanceOf(treasury) - treasuryBefore;
        uint256 spent       = bobBefore - tokenA.balanceOf(bob);

        // vault(15bps) + treasury(10bps) = 25bps of amtIn
        uint256 expectedFees = (amtIn * 25) / 10000;
        assertApproxEqAbs(vaultFee + treasuryFee, expectedFees, 2, "fee split sum wrong");
        assertEq(spent, amtIn, "bob should spend exactly amtIn");
    }
}
