// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}              from "forge-std/Test.sol";
import {FeeConverter}      from "../../src/FeeConverter.sol";
import {ILShieldVault}     from "../../src/ILShieldVault.sol";
import {Router}            from "../../src/Router.sol";
import {Factory}           from "../../src/FactoryContract.sol";
import {Pair}              from "../../src/Pair.sol";
import {TWAPOracle}        from "../../src/TWAPOracle.sol";
import {ILPositionManager} from "../../src/ILPositionManager.sol";
import {MockERC20}         from "../mocks/MockERC20.sol";

contract FeeConverterFuzz is Test {

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

    address internal pair;

    // Pool: 1_000_000 feeToken : 2_000_000 USDC (1 FEE = 2 USDC)
    // Large pool so even max fuzz fee amounts stay well under 1% price impact
    uint256 constant POOL_FEE  = 1_000_000 ether;
    uint256 constant POOL_USDC = 2_000_000 * 1e6;

    uint256 constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);

        usdc     = new MockERC20("USDC",     "USDC", 6);
        feeToken = new MockERC20("FeeToken", "FEE",  18);

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

        pair = factory.createPair(address(feeToken), address(usdc));

        feeToken.mint(owner, POOL_FEE);
        usdc.mint(owner, POOL_USDC);

        vm.startPrank(owner);
        feeToken.transfer(pair, POOL_FEE);
        usdc.transfer(pair, POOL_USDC);
        Pair(pair).mint(owner);
        vm.stopPrank();

        // Bootstrap TWAP: two snapshots 2 hours apart
        vm.warp(T0 + 1);
        Pair(pair).sync();
        vm.prank(keeper);
        oracle.update(pair);

        vm.warp(T0 + 1 + 2 hours);
        Pair(pair).sync();
        vm.prank(keeper);
        oracle.update(pair);

        vm.warp(T0 + 1 + 3 hours);
        Pair(pair).sync();

        // Seed vault with USDC so allocateUSDC can pull from converter
        usdc.mint(address(vault), 10_000_000 * 1e6);
    }

    /// @dev Seed fees, run convert(), verify caller bonus never exceeds MAX_CALLER_BONUS
    function testFuzz_callerBonus_neverExceedsMax(uint256 feeAmt) public {
        // Keep fee small enough that price impact stays under 1% slippage cap.
        // Pool has 1M feeToken. 0.1% of pool = 1000 ether → ~0.1% impact, safe.
        feeAmt = bound(feeAmt, 10 ether, 1_000 ether);

        feeToken.mint(address(vault), feeAmt);
        vm.prank(address(router));
        vault.depositFees(pair, address(feeToken), feeAmt);

        uint256 keeperBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        converter.convert(pair, address(feeToken));

        uint256 bonus = usdc.balanceOf(keeper) - keeperBefore;
        assertLe(bonus, converter.MAX_CALLER_BONUS(), "bonus exceeded hard cap");
    }

    /// @dev Vault must always receive >= 99.9% of converted USDC (caller gets <= 0.1%)
    function testFuzz_vaultGetsAtLeast999PerMille(uint256 feeAmt) public {
        feeAmt = bound(feeAmt, 10 ether, 1_000 ether);

        feeToken.mint(address(vault), feeAmt);
        vm.prank(address(router));
        vault.depositFees(pair, address(feeToken), feeAmt);

        uint256 vaultBefore  = usdc.balanceOf(address(vault));
        uint256 keeperBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        converter.convert(pair, address(feeToken));

        uint256 vaultGot  = usdc.balanceOf(address(vault))  - vaultBefore;
        uint256 callerGot = usdc.balanceOf(keeper) - keeperBefore;
        uint256 total     = vaultGot + callerGot;

        if (total == 0) return; // nothing converted (dust below minimum)

        // Caller gets at most 0.1% (10 bps) of total, unless hard cap kicks in
        // When hard cap kicks in, vault gets even more — still fine
        uint256 callerBps = (callerGot * 10000) / total;
        assertLe(callerBps, converter.CALLER_BONUS_BPS() + 1, "caller took too much");
    }

    /// @dev Fake pair (not in Factory) must always revert PairNotRegistered
    function testFuzz_fakePair_alwaysReverts(address fakePair) public {
        // Exclude the real pair and zero address
        vm.assume(fakePair != pair);
        vm.assume(fakePair != address(0));
        vm.assume(fakePair.code.length == 0); // not a deployed contract

        vm.prank(keeper);
        vm.expectRevert();
        converter.convert(fakePair, address(feeToken));
    }

    /// @dev cooldownRemaining must always be <= CONVERSION_COOLDOWN
    function testFuzz_cooldownRemaining_neverExceedsCooldown(uint256 warpTime) public {
        warpTime = bound(warpTime, 0, 2 hours);

        vm.warp(T0 + 1 + 3 hours + warpTime);
        uint256 remaining = converter.cooldownRemaining(pair, address(feeToken));
        assertLe(remaining, converter.CONVERSION_COOLDOWN());
    }
}
