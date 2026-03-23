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

    address internal pair;         // feeToken/usdc pair (for TWAP)
    address internal swapPair;     // tokenA/tokenB pair (for fee accumulation)

    function setUp() public {
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
        oracle.setUpdater(keeper, true);
        vm.stopPrank();

        // Create feeToken/USDC pair for TWAP and swaps
        pair = factory.createPair(address(feeToken), address(usdc));

        // Seed liquidity: 1 feeToken = 2 USDC (price = 2e6 USDC per 1e18 feeToken)
        feeToken.mint(owner, 1_000_000 ether);
        usdc.mint(owner, 2_000_000 * 1e6);

        vm.startPrank(owner);
        feeToken.transfer(pair, 100_000 ether);
        usdc.transfer(pair, 200_000 * 1e6);
        Pair(pair).mint(owner);
        vm.stopPrank();

        // Bootstrap oracle: snapshot, advance past MIN_UPDATE_INTERVAL, sync
        vm.prank(keeper);
        oracle.update(pair);
        vm.warp(block.timestamp + 6 minutes);
        Pair(pair).sync();
        
        // Advance time further to ensure TWAP is valid (past MIN_UPDATE_INTERVAL from snapshot)
        vm.warp(block.timestamp + 1 minutes);
        
        // CRITICAL FIX: The FeeConverter's cooldownRemaining treats lastConversion[pair][token] = 0
        // as "conversion happened at timestamp 0", not "no conversion yet".
        // So we need to warp past the cooldown period (1 hour) to make cooldownRemaining return 0.
        // Current timestamp after oracle bootstrap: ~421 seconds
        // We need to be at least 3600 seconds (1 hour) to clear the cooldown from timestamp 0
        vm.warp(3601); // Just past 1 hour mark

        // Seed vault with raw fee balances AND actual feeToken balance
        feeToken.mint(address(vault), 10_000 ether);
        vm.prank(address(router));
        vault.depositFees(pair, address(feeToken), 10_000 ether);

        // Converter needs USDC approval to vault for allocateUSDC
        usdc.mint(address(converter), 1_000_000 * 1e6);
        vm.prank(address(converter));
        usdc.approve(address(vault), type(uint256).max);
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    function _convert() internal {
        vm.prank(keeper);
        converter.convert(pair, address(feeToken));
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
    // CONVERT — REVERT CASES
    // -------------------------------------------------------

    function test_convert_tokenIsUSDC_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.TokenIsUSDC.selector);
        converter.convert(pair, address(usdc));
    }

    function test_convert_cooldownNotMet_reverts() public {
        _convert();
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.CooldownNotMet.selector);
        converter.convert(pair, address(feeToken));
    }

    function test_convert_nothingToConvert_reverts() public {
        // First conversion consumes the 10k feeToken
        _convert();
        
        // Advance past cooldown
        vm.warp(block.timestamp + 2 hours);
        
        // Now rawFeeBalances[pair][feeToken] == 0
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.NothingToConvert.selector);
        converter.convert(pair, address(feeToken));
    }

    function test_convert_staleOracle_reverts() public {
        // Advance past MAX_STALENESS (2 hours)
        vm.warp(block.timestamp + 3 hours);
        vm.prank(keeper);
        vm.expectRevert(FeeConverter.TWAPUnavailable.selector);
        converter.convert(pair, address(feeToken));
    }

    // -------------------------------------------------------
    // COOLDOWN
    // -------------------------------------------------------

    function test_cooldownRemaining_zeroBeforeFirstConversion() public view {
        uint256 remaining = converter.cooldownRemaining(pair, address(feeToken));
        assertEq(remaining, 0, "cooldown should be 0 before first conversion");
    }

    function test_cooldownRemaining_nonZeroAfterConversion() public {
        _convert();
        assertGt(converter.cooldownRemaining(pair, address(feeToken)), 0);
    }

    function test_cooldownRemaining_zeroAfterCooldown() public {
        _convert();
        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(converter.cooldownRemaining(pair, address(feeToken)), 0);
    }

    // -------------------------------------------------------
    // TRANSFER OWNERSHIP
    // -------------------------------------------------------

    function test_transferOwnership_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(FeeConverter.NotOwner.selector);
        converter.transferOwnership(alice);
    }

    function test_transferOwnership_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(FeeConverter.ZeroAddress.selector);
        converter.transferOwnership(address(0));
    }

    function test_transferOwnership_transfers() public {
        vm.prank(owner); converter.transferOwnership(keeper);
        assertEq(converter.owner(), keeper);
    }

    // -------------------------------------------------------
    // PREVIEW CONVERSION
    // -------------------------------------------------------

    function test_previewConversion_returnsFalseForUSDC() public view {
        (,,,,bool ok) = converter.previewConversion(pair, address(usdc));
        assertFalse(ok);
    }

    function test_previewConversion_returnsFalseAfterCooldown() public {
        _convert();
        (,,,,bool ok) = converter.previewConversion(pair, address(feeToken));
        assertFalse(ok);
    }

    function test_previewConversion_returnsTrueWhenConvertible() public view {
        (uint256 raw, uint256 expected,,,bool ok) = converter.previewConversion(pair, address(feeToken));
        assertTrue(ok);
        assertGt(raw, 0);
        assertGt(expected, 0);
    }
}

// Helper to expose makeAddr in FeeConverterTest
address constant alice = address(0xA11CE);
