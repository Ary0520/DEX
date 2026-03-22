// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20}  from "../mocks/MockERC20.sol";
import {Factory}    from "../../src/FactoryContract.sol";
import {Pair}       from "../../src/Pair.sol";

contract FactoryTest is Test {

    Factory   internal factory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;
    MockERC20 internal stable1;
    MockERC20 internal stable2;
    MockERC20 internal bluechip1;
    MockERC20 internal bluechip2;
    MockERC20 internal volatile1;

    address internal admin    = makeAddr("admin");
    address internal alice    = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.startPrank(admin);
        factory = new Factory();
        vm.stopPrank();

        tokenA    = new MockERC20("Token A",    "TKA",  18);
        tokenB    = new MockERC20("Token B",    "TKB",  18);
        tokenC    = new MockERC20("Token C",    "TKC",  18);
        stable1   = new MockERC20("USDC",       "USDC", 6);
        stable2   = new MockERC20("DAI",        "DAI",  18);
        bluechip1 = new MockERC20("WETH",       "WETH", 18);
        bluechip2 = new MockERC20("WBTC",       "WBTC", 8);
        volatile1 = new MockERC20("SHIB",       "SHIB", 18);

        vm.label(address(factory),   "Factory");
        vm.label(address(stable1),   "USDC");
        vm.label(address(stable2),   "DAI");
        vm.label(address(bluechip1), "WETH");
        vm.label(address(bluechip2), "WBTC");
        vm.label(address(volatile1), "SHIB");
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    function _whitelistTokens() internal {
        vm.startPrank(admin);
        factory.setTokenTier(address(stable1),   true,  false);
        factory.setTokenTier(address(stable2),   true,  false);
        factory.setTokenTier(address(bluechip1), false, true);
        factory.setTokenTier(address(bluechip2), false, true);
        vm.stopPrank();
    }

    // -------------------------------------------------------
    // CONSTRUCTOR / INITIAL STATE
    // -------------------------------------------------------

    function test_constructor_feeToSetterIsDeployer() public view {
        assertEq(factory.feeToSetter(), admin, "feeToSetter should be deployer");
    }

    function test_constructor_feeToIsZero() public view {
        assertEq(factory.feeTo(), address(0), "feeTo should start as zero");
    }

    function test_constructor_allPairsLengthZero() public view {
        assertEq(factory.allPairsLength(), 0, "allPairs should be empty initially");
    }

    function test_constructor_volatileTierConfig() public view {
        (uint256 vault, uint256 treasury, uint256 lp, uint256 coverage) =
            factory.tierConfig(Factory.Tier.Volatile);
        assertEq(vault,    15,   "volatile vaultFee wrong");
        assertEq(treasury, 10,   "volatile treasuryFee wrong");
        assertEq(lp,       30,   "volatile lpFee wrong");
        assertEq(coverage, 7500, "volatile coverage wrong");
    }

    function test_constructor_bluechipTierConfig() public view {
        (uint256 vault, uint256 treasury, uint256 lp, uint256 coverage) =
            factory.tierConfig(Factory.Tier.BlueChip);
        assertEq(vault,    10,   "bluechip vaultFee wrong");
        assertEq(treasury, 5,    "bluechip treasuryFee wrong");
        assertEq(lp,       20,   "bluechip lpFee wrong");
        assertEq(coverage, 5000, "bluechip coverage wrong");
    }

    function test_constructor_stableTierConfig() public view {
        (uint256 vault, uint256 treasury, uint256 lp, uint256 coverage) =
            factory.tierConfig(Factory.Tier.Stable);
        assertEq(vault,    3,    "stable vaultFee wrong");
        assertEq(treasury, 2,    "stable treasuryFee wrong");
        assertEq(lp,       5,    "stable lpFee wrong");
        assertEq(coverage, 1500, "stable coverage wrong");
    }

    // -------------------------------------------------------
    // CREATE PAIR - BASIC
    // -------------------------------------------------------

    function test_createPair_succeeds() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertTrue(pair != address(0), "pair address is zero");
    }

    function test_createPair_registersInGetPair() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair, "getPair(A,B) wrong");
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair, "getPair(B,A) wrong");
    }

    function test_createPair_appendsToAllPairs() public {
        factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.allPairsLength(), 1, "allPairs length wrong");
        assertEq(factory.allPairs(0), factory.getPair(address(tokenA), address(tokenB)));
    }

    function test_createPair_multiplePairs() public {
        factory.createPair(address(tokenA), address(tokenB));
        factory.createPair(address(tokenA), address(tokenC));
        factory.createPair(address(tokenB), address(tokenC));
        assertEq(factory.allPairsLength(), 3, "should have 3 pairs");
    }

    function test_createPair_initializesTokens() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        address t0 = Pair(pair).token0();
        address t1 = Pair(pair).token1();
        assertTrue(
            (t0 == address(tokenA) && t1 == address(tokenB)) ||
            (t0 == address(tokenB) && t1 == address(tokenA)),
            "pair tokens wrong"
        );
    }

    function test_createPair_tokensSorted() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        address t0 = Pair(pair).token0();
        address t1 = Pair(pair).token1();
        assertTrue(uint160(t0) < uint160(t1), "token0 must be lower address");
    }

    function test_createPair_emitsEvent() public {
        (address t0, address t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        vm.expectEmit(true, true, false, false);
        emit Factory.PairCreated(t0, t1, address(0), Factory.Tier.Volatile);
        factory.createPair(address(tokenA), address(tokenB));
    }

    // -------------------------------------------------------
    // CREATE PAIR - REVERT CASES
    // -------------------------------------------------------

    function test_createPair_identicalTokens_reverts() public {
        vm.expectRevert(Factory.DEX__IdenticalTokens.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_createPair_zeroTokenA_reverts() public {
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.createPair(address(0), address(tokenB));
    }

    function test_createPair_zeroTokenB_reverts() public {
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.createPair(address(tokenA), address(0));
    }

    function test_createPair_duplicate_reverts() public {
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(Factory.DEX__PairAlreadyExists.selector);
        factory.createPair(address(tokenA), address(tokenB));
    }

    function test_createPair_duplicateReversed_reverts() public {
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(Factory.DEX__PairAlreadyExists.selector);
        factory.createPair(address(tokenB), address(tokenA));
    }

    // -------------------------------------------------------
    // CREATE2 ADDRESS
    // -------------------------------------------------------

    function test_computePairAddress_matchesActual() public {
        address computed = factory.computePairAddress(address(tokenA), address(tokenB));
        address actual   = factory.createPair(address(tokenA), address(tokenB));
        assertEq(computed, actual, "computePairAddress does not match actual deployed address");
    }

    function test_computePairAddress_orderIndependent() public view{
        address ab = factory.computePairAddress(address(tokenA), address(tokenB));
        address ba = factory.computePairAddress(address(tokenB), address(tokenA));
        assertEq(ab, ba, "computePairAddress should be order-independent");
    }

    function test_computePairAddress_differentPairsAreDifferent() public view{
        address ab = factory.computePairAddress(address(tokenA), address(tokenB));
        address ac = factory.computePairAddress(address(tokenA), address(tokenC));
        assertTrue(ab != ac, "different pairs must have different addresses");
    }

    // -------------------------------------------------------
    // TIER AUTO-DETECTION
    // -------------------------------------------------------

    function test_tierDetection_bothVolatile_isVolatile() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Volatile));
    }

    function test_tierDetection_bothStable_isStable() public {
        _whitelistTokens();
        address pair = factory.createPair(address(stable1), address(stable2));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Stable));
    }

    function test_tierDetection_bothBluechip_isBluechip() public {
        _whitelistTokens();
        address pair = factory.createPair(address(bluechip1), address(bluechip2));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.BlueChip));
    }

    function test_tierDetection_stableAndBluechip_isBluechip() public {
        _whitelistTokens();
        address pair = factory.createPair(address(stable1), address(bluechip1));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.BlueChip));
    }

    function test_tierDetection_bluechipAndStable_isBluechip() public {
        _whitelistTokens();
        address pair = factory.createPair(address(bluechip1), address(stable1));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.BlueChip));
    }

    function test_tierDetection_stableAndVolatile_isVolatile() public {
        _whitelistTokens();
        address pair = factory.createPair(address(stable1), address(volatile1));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Volatile));
    }

    function test_tierDetection_bluechipAndVolatile_isVolatile() public {
        _whitelistTokens();
        address pair = factory.createPair(address(bluechip1), address(volatile1));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Volatile));
    }

    function test_detectTier_publicPreview_matchesActual() public {
        _whitelistTokens();
        Factory.Tier preview = factory.detectTier(address(stable1), address(stable2));
        address pair = factory.createPair(address(stable1), address(stable2));
        assertEq(uint256(preview), uint256(factory.pairTier(pair)), "preview tier differs from actual");
    }

    // -------------------------------------------------------
    // GET PAIR CONFIG
    // -------------------------------------------------------

    function test_getPairConfig_volatilePair() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        (uint256 vault, uint256 treasury, uint256 lp, uint256 coverage) =
            factory.getPairConfig(pair);
        assertEq(vault,    15,   "vault fee wrong");
        assertEq(treasury, 10,   "treasury fee wrong");
        assertEq(lp,       30,   "lp fee wrong");
        assertEq(coverage, 7500, "coverage wrong");
    }

    function test_getPairConfig_stablePair() public {
        _whitelistTokens();
        address pair = factory.createPair(address(stable1), address(stable2));
        (uint256 vault, uint256 treasury, uint256 lp, uint256 coverage) =
            factory.getPairConfig(pair);
        assertEq(vault,    3,    "vault fee wrong");
        assertEq(treasury, 2,    "treasury fee wrong");
        assertEq(lp,       5,    "lp fee wrong");
        assertEq(coverage, 1500, "coverage wrong");
    }

    function test_getPairConfig_bluechipPair() public {
        _whitelistTokens();
        address pair = factory.createPair(address(bluechip1), address(bluechip2));
        (uint256 vault, uint256 treasury, uint256 lp, uint256 coverage) =
            factory.getPairConfig(pair);
        assertEq(vault,    10,   "vault fee wrong");
        assertEq(treasury, 5,    "treasury fee wrong");
        assertEq(lp,       20,   "lp fee wrong");
        assertEq(coverage, 5000, "coverage wrong");
    }

    // -------------------------------------------------------
    // SET PAIR TIER (ADMIN OVERRIDE)
    // -------------------------------------------------------

    function test_setPairTier_adminCanOverride() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Volatile));

        vm.prank(admin);
        factory.setPairTier(pair, Factory.Tier.Stable);

        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Stable));
    }

    function test_setPairTier_emitsEvent() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));

        vm.expectEmit(true, false, false, true);
        emit Factory.TierOverridden(pair, Factory.Tier.Volatile, Factory.Tier.BlueChip);

        vm.prank(admin);
        factory.setPairTier(pair, Factory.Tier.BlueChip);
    }

    function test_setPairTier_nonAdmin_reverts() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        vm.prank(stranger);
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setPairTier(pair, Factory.Tier.Stable);
    }

    function test_setPairTier_zeroPairAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.setPairTier(address(0), Factory.Tier.Stable);
    }

    function test_setPairTier_unregisteredPair_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__PairNotFound.selector);
        factory.setPairTier(address(0xDEAD), Factory.Tier.Stable);
    }

    function test_setPairTier_configUpdatesViaGetPairConfig() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));

        vm.prank(admin);
        factory.setPairTier(pair, Factory.Tier.Stable);

        (uint256 vault,,,) = factory.getPairConfig(pair);
        assertEq(vault, 3, "config should reflect new stable tier");
    }

    // -------------------------------------------------------
    // SET TIER CONFIG
    // -------------------------------------------------------

    function test_setTierConfig_adminCanUpdate() public {
        vm.prank(admin);
        factory.setTierConfig(Factory.Tier.Volatile, 20, 10, 30, 8000);

        (uint256 vault, uint256 treasury, uint256 lp, uint256 coverage) =
            factory.tierConfig(Factory.Tier.Volatile);
        assertEq(vault,    20,   "vault wrong after update");
        assertEq(treasury, 10,   "treasury wrong after update");
        assertEq(lp,       30,   "lp wrong after update");
        assertEq(coverage, 8000, "coverage wrong after update");
    }

    function test_setTierConfig_affectsAllPairsInTierImmediately() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        (uint256 vaultBefore,,,) = factory.getPairConfig(pair);
        assertEq(vaultBefore, 15, "should start at 15");

        vm.prank(admin);
        factory.setTierConfig(Factory.Tier.Volatile, 20, 10, 30, 8000);

        (uint256 vaultAfter,,,) = factory.getPairConfig(pair);
        assertEq(vaultAfter, 20, "pair config should update immediately");
    }

    function test_setTierConfig_nonAdmin_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setTierConfig(Factory.Tier.Volatile, 20, 10, 30, 8000);
    }

    function test_setTierConfig_vaultFeeTooHigh_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__InvalidConfig.selector);
        factory.setTierConfig(Factory.Tier.Volatile, 201, 0, 0, 7500);
    }

    function test_setTierConfig_treasuryFeeTooHigh_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__InvalidConfig.selector);
        factory.setTierConfig(Factory.Tier.Volatile, 0, 201, 0, 7500);
    }

    function test_setTierConfig_lpFeeTooHigh_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__InvalidConfig.selector);
        factory.setTierConfig(Factory.Tier.Volatile, 0, 0, 201, 7500);
    }

    function test_setTierConfig_totalFeeExceeds200bps_reverts() public {
        // 100 + 60 + 60 = 220 > 200
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__InvalidConfig.selector);
        factory.setTierConfig(Factory.Tier.Volatile, 100, 60, 60, 7500);
    }

    function test_setTierConfig_coverageOver10000_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__InvalidConfig.selector);
        factory.setTierConfig(Factory.Tier.Volatile, 15, 10, 30, 10001);
    }

    function test_setTierConfig_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit Factory.TierConfigUpdated(Factory.Tier.Volatile,
            Factory.TierConfig({vaultFeeBps: 20, treasuryFeeBps: 10, lpFeeBps: 30, maxCoverageBps: 8000}));
        factory.setTierConfig(Factory.Tier.Volatile, 20, 10, 30, 8000);
    }

    // -------------------------------------------------------
    // SET TOKEN TIER (WHITELIST)
    // -------------------------------------------------------

    function test_setTokenTier_markAsStable() public {
        vm.prank(admin);
        factory.setTokenTier(address(tokenA), true, false);
        assertTrue(factory.isStableToken(address(tokenA)), "should be stable");
        assertFalse(factory.isBlueChipToken(address(tokenA)), "should not be bluechip");
    }

    function test_setTokenTier_markAsBluechip() public {
        vm.prank(admin);
        factory.setTokenTier(address(tokenA), false, true);
        assertFalse(factory.isStableToken(address(tokenA)), "should not be stable");
        assertTrue(factory.isBlueChipToken(address(tokenA)), "should be bluechip");
    }

    function test_setTokenTier_markAsVolatile() public {
        vm.prank(admin);
        factory.setTokenTier(address(tokenA), true, false);
        vm.prank(admin);
        factory.setTokenTier(address(tokenA), false, false);
        assertFalse(factory.isStableToken(address(tokenA)), "should not be stable");
        assertFalse(factory.isBlueChipToken(address(tokenA)), "should not be bluechip");
    }

    function test_setTokenTier_bothStableAndBluechip_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__InvalidConfig.selector);
        factory.setTokenTier(address(tokenA), true, true);
    }

    function test_setTokenTier_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.setTokenTier(address(0), true, false);
    }

    function test_setTokenTier_nonAdmin_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setTokenTier(address(tokenA), true, false);
    }

    function test_setTokenTier_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Factory.TokenWhitelistUpdated(address(tokenA), true, false);
        vm.prank(admin);
        factory.setTokenTier(address(tokenA), true, false);
    }

    function test_setTokenTier_affectsFuturePairDetection() public {
        vm.startPrank(admin);
        factory.setTokenTier(address(tokenA), true, false);
        factory.setTokenTier(address(tokenB), true, false);
        vm.stopPrank();

        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Stable),
            "pair should be stable after token whitelist");
    }

    function test_setTokenTier_doesNotAffectExistingPairs() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Volatile));

        vm.startPrank(admin);
        factory.setTokenTier(address(tokenA), true, false);
        factory.setTokenTier(address(tokenB), true, false);
        vm.stopPrank();

        assertEq(uint256(factory.pairTier(pair)), uint256(Factory.Tier.Volatile),
            "existing pair tier should not auto-update");
    }

    // -------------------------------------------------------
    // SET FEE TO
    // -------------------------------------------------------

    function test_setFeeTo_adminCanSet() public {
        vm.prank(admin);
        factory.setFeeTo(alice);
        assertEq(factory.feeTo(), alice, "feeTo not updated");
    }

    function test_setFeeTo_nonAdmin_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setFeeTo(alice);
    }

    function test_setFeeTo_canSetToZero() public {
        vm.prank(admin);
        factory.setFeeTo(alice);
        vm.prank(admin);
        factory.setFeeTo(address(0));
        assertEq(factory.feeTo(), address(0), "feeTo should be resettable to zero");
    }

    // -------------------------------------------------------
    // SET FEE TO SETTER
    // -------------------------------------------------------

    function test_setFeeToSetter_transfersAdmin() public {
        vm.prank(admin);
        factory.setFeeToSetter(alice);
        assertEq(factory.feeToSetter(), alice, "feeToSetter not updated");
    }

    function test_setFeeToSetter_oldAdminLosesAccess() public {
        vm.prank(admin);
        factory.setFeeToSetter(alice);

        vm.prank(admin);
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setFeeTo(makeAddr("anyone"));
    }

    function test_setFeeToSetter_newAdminHasAccess() public {
        vm.prank(admin);
        factory.setFeeToSetter(alice);

        vm.prank(alice);
        factory.setFeeTo(makeAddr("anyone"));
        assertEq(factory.feeTo(), makeAddr("anyone"));
    }

    function test_setFeeToSetter_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.setFeeToSetter(address(0));
    }

    function test_setFeeToSetter_nonAdmin_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setFeeToSetter(alice);
    }

    // -------------------------------------------------------
    // FUZZ
    // -------------------------------------------------------

    function testFuzz_createPair_computedAddressAlwaysMatches(
        uint256 saltA,
        uint256 saltB
    ) public {
        saltA = bound(saltA, 1, type(uint128).max);
        saltB = bound(saltB, 1, type(uint128).max);

        MockERC20 tA = new MockERC20("A", "A", 18);
        MockERC20 tB = new MockERC20("B", "B", 18);

        if (address(tA) == address(tB)) return;

        address computed = factory.computePairAddress(address(tA), address(tB));
        address actual   = factory.createPair(address(tA), address(tB));
        assertEq(computed, actual, "CREATE2 address mismatch");
    }

    function testFuzz_setTierConfig_totalFeeNeverExceeds200(
        uint256 v, uint256 t, uint256 l
    ) public {
        v = bound(v, 0, 200);
        t = bound(t, 0, 200);
        l = bound(l, 0, 200);

        vm.prank(admin);
        if (v + t + l > 200) {
            vm.expectRevert(Factory.DEX__InvalidConfig.selector);
        }
        factory.setTierConfig(Factory.Tier.Volatile, v, t, l, 7500);
    }
}