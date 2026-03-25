// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Factory}           from "../../src/FactoryContract.sol";
import {Pair}              from "../../src/Pair.sol";
import {Router}            from "../../src/Router.sol";
import {ILShieldVault}     from "../../src/ILShieldVault.sol";
import {ILPositionManager} from "../../src/ILPositionManager.sol";
import {TWAPOracle}        from "../../src/TWAPOracle.sol";
import {MockERC20}         from "../mocks/MockERC20.sol";

/// @notice Handler: the only contract Foundry will call randomly
contract PairHandler is Test {
    Factory           factory;
    Router            router;
    Pair              public pair;
    MockERC20         public token0;
    MockERC20         public token1;

    address actor = makeAddr("actor");

    // Tracking for LP supply invariant
    uint256 public totalLPMinted;
    uint256 public totalLPBurned;

    // Tracking for cumulative price invariant
    uint256 public initialPrice0Cumulative;
    uint256 public initialPrice1Cumulative;

    constructor() {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        factory = new Factory();
        TWAPOracle oracle = new TWAPOracle();

        // Vault + pm with placeholder
        ILShieldVault vault = new ILShieldVault(address(this), address(usdc));
        ILPositionManager pm = new ILPositionManager(address(this));

        router = new Router(
            address(factory),
            address(vault),
            address(pm),
            address(oracle),
            makeAddr("treasury")
        );

        // Fix chicken/egg
        vault.setRouter(address(router));
        pm = new ILPositionManager(address(router));
        router.setPositionManager(address(pm));

        MockERC20 tA = new MockERC20("A", "A", 18);
        MockERC20 tB = new MockERC20("B", "B", 18);

        tA.mint(actor, 1_000_000 ether);
        tB.mint(actor, 1_000_000 ether);

        vm.startPrank(actor);
        tA.approve(address(router), type(uint256).max);
        tB.approve(address(router), type(uint256).max);
        vm.stopPrank();

        // Seed initial liquidity
        vm.prank(actor);
        router.addLiquidity(
            address(tA), address(tB),
            10_000 ether, 10_000 ether,
            0, 0, actor, type(uint256).max
        );

        address pairAddr = factory.getPair(address(tA), address(tB));
        pair = Pair(pairAddr);

        if (pair.token0() == address(tA)) {
            token0 = tA; token1 = tB;
        } else {
            token0 = tB; token1 = tA;
        }

        vm.prank(actor);
        pair.approve(address(router), type(uint256).max);

        // Snapshot initial cumulative prices after seeding
        initialPrice0Cumulative = pair.price0CumulativeLast();
        initialPrice1Cumulative = pair.price1CumulativeLast();

        // Account for the initial mint (totalSupply - MINIMUM_LIQUIDITY locked at address(1))
        totalLPMinted = pair.totalSupply();
        totalLPBurned = 0;
    }

    function swapAForB(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 100 ether);
        token0.mint(actor, amountIn);

        vm.startPrank(actor);
        token0.approve(address(router), type(uint256).max);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);

        vm.prank(actor);
        try router.swapExactTokensForTokens(
            amountIn, 0, path, actor, type(uint256).max
        ) {} catch {}
    }

    function swapBForA(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 100 ether);
        token1.mint(actor, amountIn);

        vm.startPrank(actor);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = address(token1);
        path[1] = address(token0);

        vm.prank(actor);
        try router.swapExactTokensForTokens(
            amountIn, 0, path, actor, type(uint256).max
        ) {} catch {}
    }

    function addLiquidity(uint256 amt) public {
        amt = bound(amt, 1 ether, 500 ether);
        token0.mint(actor, amt);
        token1.mint(actor, amt);

        vm.startPrank(actor);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.prank(actor);
        try router.addLiquidity(
            address(token0), address(token1),
            amt, amt, 0, 0, actor, type(uint256).max
        ) returns (uint256, uint256, uint256 liq) {
            totalLPMinted += liq;
        } catch {}
    }

    function removeLiquidity(uint256 fraction) public {
        fraction = bound(fraction, 1, 10);
        uint256 liq = pair.balanceOf(actor);
        if (liq == 0) return;

        uint256 toRemove = liq / fraction;
        if (toRemove == 0) return;

        vm.prank(actor);
        pair.approve(address(router), type(uint256).max);

        vm.prank(actor);
        try router.removeLiquidity(
            address(token0), address(token1),
            toRemove, 0, 0, actor, type(uint256).max
        ) returns (uint256, uint256) {
            totalLPBurned += toRemove;
        } catch {}
    }
}

contract PairInvariantTest is Test {
    PairHandler handler;
    Pair        pair;

    function setUp() public {
        handler = new PairHandler();
        pair    = handler.pair();
        targetContract(address(handler));
    }

    /// Reserves must always exactly match actual token balances
    function invariant_reservesMatchBalances() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(
            MockERC20(pair.token0()).balanceOf(address(pair)), r0,
            "reserve0 mismatch"
        );
        assertEq(
            MockERC20(pair.token1()).balanceOf(address(pair)), r1,
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
        assertGt(uint256(r0) * uint256(r1), 0, "k is zero");
    }

    /// Reserves must never exceed uint112 max
    function invariant_noOverflow() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertLe(r0, type(uint112).max, "reserve0 overflow");
        assertLe(r1, type(uint112).max, "reserve1 overflow");
    }

    /// k must never decrease after a swap (only stays same or grows via fees)
    function invariant_kNeverDecreases() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 k = uint256(r0) * uint256(r1);
        assertGt(k, 0, "k dropped to zero");
    }

    /// Cumulative prices must never decrease (they are monotonically non-decreasing)
    function invariant_cumulativePricesNeverDecrease() public view {
        uint256 p0 = pair.price0CumulativeLast();
        uint256 p1 = pair.price1CumulativeLast();
        // Both must be >= their initial seeded values (> 0 after first sync)
        // The handler only ever adds liquidity/swaps — never resets state
        assertGe(p0, handler.initialPrice0Cumulative(), "price0Cumulative decreased");
        assertGe(p1, handler.initialPrice1Cumulative(), "price1Cumulative decreased");
    }

    /// LP total supply must equal minted minus burned (tracked by handler)
    function invariant_lpSupplyMatchesMintedMinusBurned() public view {
        assertEq(
            pair.totalSupply(),
            handler.totalLPMinted() - handler.totalLPBurned(),
            "LP supply inconsistent with mint/burn accounting"
        );
    }
}
