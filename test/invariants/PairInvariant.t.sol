// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../../src/FactoryContract.sol";
import {Pair} from "../../src/Pair.sol";
import {Router} from "../../src/Router.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Handler: the only contract Foundry will call randomly
contract PairHandler is Test {
    Factory public factory;
    Router public router;
    Pair public pair;
    MockERC20 public token0;
    MockERC20 public token1;

    address actor = makeAddr("actor");

    // track k at start of each action for comparison
    uint public kBefore;

    constructor() {
        factory = new Factory();
        router = new Router(address(factory));

        MockERC20 tA = new MockERC20("A", "A");
        MockERC20 tB = new MockERC20("B", "B");

        tA.mint(actor, 1_000_000 ether);
        tB.mint(actor, 1_000_000 ether);

        vm.startPrank(actor);
        tA.approve(address(router), type(uint).max);
        tB.approve(address(router), type(uint).max);
        vm.stopPrank();

        // seed initial liquidity
        vm.prank(actor);
        router.addLiquidity(
            address(tA), address(tB),
            10_000 ether, 10_000 ether,
            0, 0, actor, type(uint).max
        );

        address pairAddr = factory.getPair(address(tA), address(tB));
        pair = Pair(pairAddr);

        // align token0/token1 with pair's sorted order
        if (pair.token0() == address(tA)) {
            token0 = tA;
            token1 = tB;
        } else {
            token0 = tB;
            token1 = tA;
        }

        vm.prank(actor);
        pair.approve(address(router), type(uint).max);
    }

    function swapAForB(uint amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 100 ether);
        token0.mint(actor, amountIn);
        vm.prank(actor);
        token0.approve(address(router), type(uint).max);

        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);

        vm.prank(actor);
        try router.swapExactTokensForTokens(
            amountIn, 0, path, actor, type(uint).max
        ) {} catch {}
    }

    function swapBForA(uint amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 100 ether);
        token1.mint(actor, amountIn);
        vm.prank(actor);
        token1.approve(address(router), type(uint).max);

        address[] memory path = new address[](2);
        path[0] = address(token1);
        path[1] = address(token0);

        vm.prank(actor);
        try router.swapExactTokensForTokens(
            amountIn, 0, path, actor, type(uint).max
        ) {} catch {}
    }

    function addLiquidity(uint amt) public {
        amt = bound(amt, 1 ether, 500 ether);
        token0.mint(actor, amt);
        token1.mint(actor, amt);
        vm.prank(actor);
        token0.approve(address(router), type(uint).max);
        vm.prank(actor);
        token1.approve(address(router), type(uint).max);

        vm.prank(actor);
        try router.addLiquidity(
            address(token0), address(token1),
            amt, amt, 0, 0, actor, type(uint).max
        ) {} catch {}
    }

    function removeLiquidity(uint fraction) public {
        fraction = bound(fraction, 1, 10); // remove 1/10 to 10/10 of holdings
        uint liq = pair.balanceOf(actor);
        if (liq == 0) return;
        uint toRemove = liq / fraction;
        if (toRemove == 0) return;

        vm.prank(actor);
        pair.approve(address(router), type(uint).max);

        vm.prank(actor);
        try router.removeLiquidity(
            address(token0), address(token1),
            toRemove, 0, 0, actor, type(uint).max
        ) {} catch {}
    }
}

contract PairInvariantTest is Test {
    PairHandler handler;
    Pair pair;

    function setUp() public {
        handler = new PairHandler();
        pair = handler.pair();

        targetContract(address(handler));
    }

    /// Reserves must always exactly match actual token balances in the pair
    function invariant_reservesMatchBalances() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(
            MockERC20(pair.token0()).balanceOf(address(pair)),
            r0,
            "reserve0 mismatch"
        );
        assertEq(
            MockERC20(pair.token1()).balanceOf(address(pair)),
            r1,
            "reserve1 mismatch"
        );
    }

    /// Total LP supply must never drop to zero once seeded
    function invariant_totalSupplyNeverZero() public view {
        assertGt(pair.totalSupply(), 0, "total supply is zero");
    }

    /// Both reserves must always be > 0 once seeded
    function invariant_reservesNeverZero() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGt(r0, 0, "reserve0 is zero");
        assertGt(r1, 0, "reserve1 is zero");
    }

    /// k = reserve0 * reserve1 must never be zero
    function invariant_kNeverZero() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGt(uint(r0) * uint(r1), 0, "k is zero");
    }

    /// Pair's token balances must never exceed uint112 max (overflow guard)
    function invariant_noOverflow() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertLe(r0, type(uint112).max, "reserve0 overflow");
        assertLe(r1, type(uint112).max, "reserve1 overflow");
    }
}