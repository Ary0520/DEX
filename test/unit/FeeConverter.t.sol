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
        vm.warp(block.timestamp + 31 minutes);
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
    // TRANSFER OWNERSHIP
    // -------------------------------------------------------

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
