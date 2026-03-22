// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2}   from "forge-std/Test.sol";
import {ILShieldVault}    from "../../src/ILShieldVault.sol";
import {MockERC20}        from "../mocks/MockERC20.sol";

contract ILShieldVaultTest is Test {

    ILShieldVault internal vault;
    MockERC20     internal usdc;
    MockERC20     internal feeToken;

    address internal owner     = makeAddr("owner");
    address internal router    = makeAddr("router");
    address internal converter = makeAddr("converter");
    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");
    address internal carol     = makeAddr("carol");
    address internal stranger  = makeAddr("stranger");
    address internal pair      = makeAddr("pair");

    uint256 internal constant USDC_DEC = 1e6;

    function setUp() public {
        usdc     = new MockERC20("USD Coin",  "USDC", 6);
        feeToken = new MockERC20("Fee Token", "FEE",  18);

        vm.startPrank(owner);
        vault = new ILShieldVault(router, address(usdc));
        vault.setFeeConverter(converter);
        vm.stopPrank();

        usdc.mint(alice,   10_000_000 * USDC_DEC);
        usdc.mint(bob,     10_000_000 * USDC_DEC);
        usdc.mint(owner,   10_000_000 * USDC_DEC);
        usdc.mint(converter, 10_000_000 * USDC_DEC);

        feeToken.mint(pair, 1_000_000 ether);

        vm.prank(alice);   usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);     usdc.approve(address(vault), type(uint256).max);
        vm.prank(owner);   usdc.approve(address(vault), type(uint256).max);
        vm.prank(converter); usdc.approve(address(vault), type(uint256).max);
    }

    // -------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------

    function _stake(address user, address p, uint256 amount) internal {
        vm.prank(user);
        vault.stake(p, amount);
    }

    function _depositFees(address p, address token, uint256 amount) internal {
        vm.prank(router);
        vault.depositFees(p, token, amount);
    }

    function _allocateUSDC(address p, uint256 amount) internal {
        vm.prank(owner);
        vault.allocateUSDC(p, amount);
    }

    function _requestPayout(
        address p,
        address user,
        uint256 netIL,
        uint256 lpValue,
        uint256 tierCeiling,
        uint256 secondsIn
    ) internal returns (uint256) {
        vm.prank(router);
        return vault.requestPayout(p, user, netIL, lpValue, tierCeiling, secondsIn);
    }

    // -------------------------------------------------------
    // TESTS
    // -------------------------------------------------------

    function test_depositFees_updatesTotalFeesIn() public {
        _depositFees(pair, address(feeToken), 500e18);
        (,,,, uint256 totalFeesIn,) = _getPoolBasic(pair);
        assertEq(totalFeesIn, 500e18);
    }

    function test_allocateUSDC_updatesReserve() public {
        _allocateUSDC(pair, 1000 * USDC_DEC);
        (uint256 reserve,,,,,) = _getPoolBasic(pair);
        assertGt(reserve, 0);
    }

    function test_stake_updatesPool() public {
        _stake(alice, pair, 1000 * USDC_DEC);
        (uint256 reserve, uint256 stakerDeposits,,,,) = _getPoolBasic(pair);
        assertEq(reserve, 1000 * USDC_DEC);
        assertEq(stakerDeposits, 1000 * USDC_DEC);
    }

    function test_requestPayout_updatesTotalPaidOut() public {
        _allocateUSDC(pair, 100_000 * USDC_DEC);

        uint256 payout = _requestPayout(
            pair,
            alice,
            5000 * USDC_DEC,
            50_000 * USDC_DEC,
            7500,
            60 days
        );

        (,,, uint256 totalPaidOut,,) = _getPoolBasic(pair);
        assertEq(totalPaidOut, payout);
    }

    // -------------------------------------------------------
    // INTERNAL HELPERS
    // -------------------------------------------------------

    function _getConfig() internal view returns (
        uint256 maxPayoutBps,
        uint256 poolCapBps,
        uint256 circuitBreakerBps,
        uint256 pauseThresholdBps,
        uint256 stakerFeeShareBps,
        uint256 unstakeCooldown
    ) {
        (
            maxPayoutBps,
            poolCapBps,
            circuitBreakerBps,
            pauseThresholdBps,
            stakerFeeShareBps,
            unstakeCooldown
        ) = vault.config();
    }

    function _getPoolBasic(address p) internal view returns (
        uint256 usdcReserve,
        uint256 stakerDeposits,
        uint256 feeDeposits,
        uint256 totalPaidOut,
        uint256 totalFeesIn,
        uint256 totalExposureUSDC
    ) {
        return vault.pools(p);
    }
}