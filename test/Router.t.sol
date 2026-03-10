// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Factory} from "../src/FactoryContract.sol";
import {Pair} from "../src/Pair.sol";
import {Router} from "../src/Router.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RouterTest is Test {
    Factory factory;
    Router router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint constant LARGE = 1_000_000 ether;
    uint constant DEADLINE = type(uint).max;

    function setUp() public {
        factory = new Factory();
        router = new Router(address(factory));

        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        tokenC = new MockERC20("Token C", "TKC");

        // fund alice and bob
        tokenA.mint(alice, LARGE);
        tokenB.mint(alice, LARGE);
        tokenC.mint(alice, LARGE);
        tokenA.mint(bob, LARGE);
        tokenB.mint(bob, LARGE);
        tokenC.mint(bob, LARGE);

        // alice pre-approves router
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint).max);
        tokenB.approve(address(router), type(uint).max);
        tokenC.approve(address(router), type(uint).max);
        vm.stopPrank();

        // bob pre-approves router
        vm.startPrank(bob);
        tokenA.approve(address(router), type(uint).max);
        tokenB.approve(address(router), type(uint).max);
        tokenC.approve(address(router), type(uint).max);
        vm.stopPrank();
    }

    // ─── helpers ───────────────────────────────────────────────────────────────

    /// alice adds liquidity to tokenA/tokenB pool
    function _seedPool(uint amtA, uint amtB) internal returns (uint liq) {
        vm.prank(alice);
        (, , liq) = router.addLiquidity(
            address(tokenA), address(tokenB),
            amtA, amtB,
            0, 0,
            alice,
            DEADLINE
        );
    }

    function _pairAddress(address tA, address tB) internal view returns (address) {
        return factory.getPair(tA, tB);
    }

    // ─── constructor ───────────────────────────────────────────────────────────

    function test_constructor_setsFactory() public view {
        assertEq(router.factory(), address(factory));
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        new Router(address(0));
    }

    // ─── addLiquidity ──────────────────────────────────────────────────────────

    function test_addLiquidity_createsPairIfNotExists() public {
        assertEq(_pairAddress(address(tokenA), address(tokenB)), address(0));
        _seedPool(10 ether, 10 ether);
        assertTrue(_pairAddress(address(tokenA), address(tokenB)) != address(0));
    }

    function test_addLiquidity_returnsLiquidity() public {
        uint liq = _seedPool(10 ether, 10 ether);
        assertTrue(liq > 0);
    }

    function test_addLiquidity_aliceReceivesLPTokens() public {
        _seedPool(10 ether, 10 ether);
        address pairAddr = _pairAddress(address(tokenA), address(tokenB));
        assertTrue(Pair(pairAddr).balanceOf(alice) > 0);
    }

    function test_addLiquidity_updatesReserves() public {
        _seedPool(4 ether, 8 ether);
        address pairAddr = _pairAddress(address(tokenA), address(tokenB));
        (uint112 r0, uint112 r1,) = Pair(pairAddr).getReserves();
        assertEq(r0 + r1, 12 ether);
    }

    function test_addLiquidity_secondDepositProportional() public {
        _seedPool(10 ether, 10 ether);
        // bob adds same ratio
        vm.prank(bob);
        tokenA.approve(address(router), type(uint).max);
        vm.prank(bob);
        tokenB.approve(address(router), type(uint).max);

        vm.prank(bob);
        (uint amtA, uint amtB,) = router.addLiquidity(
            address(tokenA), address(tokenB),
            5 ether, 5 ether, 0, 0, bob, DEADLINE
        );
        assertEq(amtA, 5 ether);
        assertEq(amtB, 5 ether);
    }

    function test_addLiquidity_revertsIfExpired() public {
        vm.prank(alice);
        vm.expectRevert(Router.Router__Expired.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB),
            10 ether, 10 ether, 0, 0,
            alice,
            block.timestamp - 1   // already expired
        );
    }

    function test_addLiquidity_revertsOnSlippage() public {
    // seed an unbalanced pool: 10 A, 20 B
    vm.prank(alice);
    router.addLiquidity(
        address(tokenA), address(tokenB),
        10 ether, 20 ether, 0, 0, alice, DEADLINE
    );

    // bob tries to add 5A/5B but pool ratio is 1:2
    // router will compute amountBOptimal = 10 ether, but bob only wants 5 ether
    // then it flips: amountAOptimal = 2.5 ether, which is < amountAMin=5 ether
    vm.prank(bob);
    vm.expectRevert(Router.Router__SlippageExceeded.selector);
    router.addLiquidity(
        address(tokenA), address(tokenB),
        5 ether, 5 ether,
        5 ether,   // amountAMin — will be violated
        5 ether,   // amountBMin
        bob,
        DEADLINE
    );
}

    // ─── removeLiquidity ───────────────────────────────────────────────────────

    function test_removeLiquidity_returnsTokens() public {
        uint liq = _seedPool(10 ether, 10 ether);
        address pairAddr = _pairAddress(address(tokenA), address(tokenB));

        vm.startPrank(alice);
        Pair(pairAddr).approve(address(router), type(uint).max);
        (uint amtA, uint amtB) = router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, DEADLINE
        );
        vm.stopPrank();

        assertTrue(amtA > 0);
        assertTrue(amtB > 0);
    }

    function test_removeLiquidity_burnsBothTokensCorrectly() public {
        uint liq = _seedPool(10 ether, 10 ether);
        address pairAddr = _pairAddress(address(tokenA), address(tokenB));

        uint aliceA_before = tokenA.balanceOf(alice);
        uint aliceB_before = tokenB.balanceOf(alice);

        vm.startPrank(alice);
        Pair(pairAddr).approve(address(router), type(uint).max);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice, DEADLINE
        );
        vm.stopPrank();

        assertTrue(tokenA.balanceOf(alice) > aliceA_before);
        assertTrue(tokenB.balanceOf(alice) > aliceB_before);
    }

    function test_removeLiquidity_revertsIfExpired() public {
        uint liq = _seedPool(10 ether, 10 ether);
        address pairAddr = _pairAddress(address(tokenA), address(tokenB));

        vm.startPrank(alice);
        Pair(pairAddr).approve(address(router), type(uint).max);
        vm.expectRevert(Router.Router__Expired.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq, 0, 0, alice,
            block.timestamp - 1
        );
        vm.stopPrank();
    }

    function test_removeLiquidity_revertsOnSlippage() public {
        uint liq = _seedPool(10 ether, 10 ether);
        address pairAddr = _pairAddress(address(tokenA), address(tokenB));

        vm.startPrank(alice);
        Pair(pairAddr).approve(address(router), type(uint).max);
        vm.expectRevert(Router.Router__SlippageExceeded.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB),
            liq,
            100 ether,  // impossibly high minimum
            100 ether,
            alice,
            DEADLINE
        );
        vm.stopPrank();
    }

    function test_removeLiquidity_revertsIfPairNotFound() public {
        vm.prank(alice);
        vm.expectRevert(Router.Router__PairNotFound.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenC),   // pair never created
            1 ether, 0, 0, alice, DEADLINE
        );
    }

    // ─── swapExactTokensForTokens ──────────────────────────────────────────────

    function test_swap_singleHop_succeeds() public {
        _seedPool(100 ether, 100 ether);

        uint amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint bobB_before = tokenB.balanceOf(bob);

        vm.prank(bob);
        uint[] memory amounts = router.swapExactTokensForTokens(
            amountIn, 0, path, bob, DEADLINE
        );

        assertTrue(tokenB.balanceOf(bob) > bobB_before);
        assertTrue(amounts[1] > 0);
    }

    function test_swap_singleHop_amountOutCorrect() public {
        _seedPool(100 ether, 100 ether);

        uint amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.prank(bob);
        uint[] memory amounts = router.swapExactTokensForTokens(
            amountIn, 0, path, bob, DEADLINE
        );

        uint expected = _getAmountOut(amountIn, 100 ether, 100 ether);
        assertEq(amounts[1], expected);
    }

    function test_swap_revertsOnSlippage() public {
        _seedPool(100 ether, 100 ether);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.prank(bob);
        vm.expectRevert(Router.Router__SlippageExceeded.selector);
        router.swapExactTokensForTokens(
            1 ether,
            100 ether,  // impossibly high minimum out
            path, bob, DEADLINE
        );
    }

    function test_swap_revertsIfExpired() public {
        _seedPool(100 ether, 100 ether);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.prank(bob);
        vm.expectRevert(Router.Router__Expired.selector);
        router.swapExactTokensForTokens(
            1 ether, 0, path, bob,
            block.timestamp - 1
        );
    }

    function test_swap_revertsIfPathTooShort() public {
        address[] memory path = new address[](1);
        path[0] = address(tokenA);

        vm.prank(bob);
        vm.expectRevert(Router.Router__PairNotFound.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, DEADLINE);
    }

    function test_swap_revertsIfPairNotFound() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenC); // no pair created

        vm.prank(bob);
        vm.expectRevert(Router.Router__PairNotFound.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, DEADLINE);
    }

    function test_swap_multiHop_succeeds() public {
        // create A/B and B/C pools
        _seedPool(100 ether, 100 ether);

        vm.prank(alice);
        router.addLiquidity(
            address(tokenB), address(tokenC),
            100 ether, 100 ether, 0, 0, alice, DEADLINE
        );

        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint bobC_before = tokenC.balanceOf(bob);

        vm.prank(bob);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, DEADLINE);

        assertTrue(tokenC.balanceOf(bob) > bobC_before);
    }

    function test_swap_decreasesInputBalance() public {
        _seedPool(100 ether, 100 ether);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint bobA_before = tokenA.balanceOf(bob);

        vm.prank(bob);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, DEADLINE);

        assertEq(tokenA.balanceOf(bob), bobA_before - 1 ether);
    }

    // ─── ensure modifier ──────────────────────────────────────────────────────

    function test_ensure_allowsExactDeadline() public {
        // block.timestamp == deadline should pass (> check means equal is fine)
        _seedPool(10 ether, 10 ether);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.prank(bob);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, block.timestamp);
    }

    // ─── pure math helper ─────────────────────────────────────────────────────

    function _getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint) {
        uint amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function test_fuzz_swapExact(uint96 amountIn) public {
    _seedPool(100 ether, 100 ether);
    uint amt = bound(amountIn, 0.001 ether, 5 ether);

    address[] memory path = new address[](2);
    path[0] = address(tokenA);
    path[1] = address(tokenB);

    vm.prank(bob);
    uint[] memory amounts = router.swapExactTokensForTokens(
        amt, 0, path, bob, DEADLINE
    );
    assertGt(amounts[1], 0);
    assertLt(amounts[1], amt); // output always less than input (fee taken)
}

function test_fuzz_addAndRemoveLiquidity(uint96 amt) public {
    uint a = bound(amt, 1 ether, 50 ether);

    vm.prank(alice);
    (,, uint liq) = router.addLiquidity(
        address(tokenA), address(tokenB),
        a, a, 0, 0, alice, DEADLINE
    );

    address pairAddr = _pairAddress(address(tokenA), address(tokenB));
    vm.startPrank(alice);
    Pair(pairAddr).approve(address(router), type(uint).max);
    (uint a0, uint a1) = router.removeLiquidity(
        address(tokenA), address(tokenB),
        liq, 0, 0, alice, DEADLINE
    );
    vm.stopPrank();

    assertGt(a0, 0);
    assertGt(a1, 0);
}

// ── _quote: reserveA == 0 branch ────────────────────────────────────────────
// covered indirectly but let's hit removeLiquidity on fresh pair explicitly
function test_removeLiquidity_revertsOnFreshPair() public {
    // create pair but never add liquidity → pair exists but reserves = 0
    factory.createPair(address(tokenA), address(tokenC));
    // address pairAddr = factory.getPair(address(tokenA), address(tokenC));

    // give alice fake LP tokens won't work, so just verify pair found but burn fails
    vm.prank(alice);
    vm.expectRevert(); // pair exists but no liquidity → burn reverts
    router.removeLiquidity(
        address(tokenA), address(tokenC),
        1 ether, 0, 0, alice, DEADLINE
    );
}

// ── getAmountsOut: path[i] != token0 branch (reserveIn = reserve1) ──────────
function test_swap_reverseTokenOrder() public {
    // seed pool normally
    _seedPool(100 ether, 200 ether); // unbalanced

    // swap tokenB → tokenA (reverse direction)
    address[] memory path = new address[](2);
    path[0] = address(tokenB);
    path[1] = address(tokenA);

    vm.prank(bob);
    tokenB.approve(address(router), type(uint).max);

    uint bobA_before = tokenA.balanceOf(bob);
    vm.prank(bob);
    router.swapExactTokensForTokens(1 ether, 0, path, bob, DEADLINE);
    assertGt(tokenA.balanceOf(bob), bobA_before);
}

// ── addLiquidity: amountBOptimal > amountBDesired branch ────────────────────
function test_addLiquidity_usesAmountAOptimalPath() public {
    // seed 1:2 ratio pool
    _seedPool(10 ether, 20 ether);

    // bob adds with ratio that makes amountBOptimal > amountBDesired
    // so router flips to compute amountAOptimal instead
    vm.prank(bob);
    (uint amtA, uint amtB,) = router.addLiquidity(
        address(tokenA), address(tokenB),
        10 ether,  // amountADesired
        5 ether,   // amountBDesired — less than optimal (10*20/10=20), triggers flip
        0, 0, bob, DEADLINE
    );
    // amountA should be adjusted down to match 1:2 ratio for 5 ether B
    assertEq(amtB, 5 ether);
    assertEq(amtA, 2.5 ether);
}
}
