// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Seeds initial liquidity into all pairs and bootstraps the TWAP oracle.
///
/// Run AFTER Deploy.s.sol. Update all addresses below first.
///
/// What this does:
///   1. Mints test tokens to deployer
///   2. Approves Router
///   3. Creates pairs via Router.addLiquidity (also registers IL positions)
///   4. Takes first TWAP oracle snapshot for each pair
///   5. Waits are done off-chain — after 2 hours call BootstrapOracle.s.sol
///
/// Price ratios used (realistic testnet prices):
///   1 WETH  = 2000 USDC
///   1 WBTC  = 60000 USDC  (= 30 WETH)
///   1 ARB   = 1 USDC
///   1 DAI   = 1 USDC
///   1 WETH  = 2000 DAI

import {Script, console}  from "forge-std/Script.sol";
import {MockERC20}         from "../test/mocks/MockERC20.sol";
import {Router}            from "../src/Router.sol";
import {TWAPOracle}        from "../src/TWAPOracle.sol";
import {Factory}           from "../src/FactoryContract.sol";

contract SeedLiquidity is Script {

    // ── Paste addresses from Deploy.s.sol output ──────────────────────────
    address constant FACTORY   = 0x0000000000000000000000000000000000000001; // TODO
    address constant ROUTER    = 0x0000000000000000000000000000000000000002; // TODO
    address constant ORACLE    = 0x0000000000000000000000000000000000000003; // TODO

    // ── Paste addresses from DeployTokens.s.sol output ────────────────────
    address constant USDC      = 0x0000000000000000000000000000000000000004; // TODO
    address constant WETH      = 0x0000000000000000000000000000000000000005; // TODO
    address constant WBTC      = 0x0000000000000000000000000000000000000006; // TODO
    address constant ARB       = 0x0000000000000000000000000000000000000007; // TODO
    address constant DAI       = 0x0000000000000000000000000000000000000008; // TODO

    uint256 constant DEADLINE  = type(uint256).max;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ── Step 1: Mint tokens ───────────────────────────────────────────
        MockERC20(USDC).mint(deployer, 2_000_000 * 1e6);       // 2M USDC
        MockERC20(WETH).mint(deployer, 1_000 ether);            // 1000 WETH
        MockERC20(WBTC).mint(deployer, 50 * 1e8);               // 50 WBTC
        MockERC20(ARB).mint(deployer,  1_000_000 ether);        // 1M ARB
        MockERC20(DAI).mint(deployer,  1_000_000 ether);        // 1M DAI

        // ── Step 2: Approve Router ────────────────────────────────────────
        MockERC20(USDC).approve(ROUTER, type(uint256).max);
        MockERC20(WETH).approve(ROUTER, type(uint256).max);
        MockERC20(WBTC).approve(ROUTER, type(uint256).max);
        MockERC20(ARB).approve(ROUTER,  type(uint256).max);
        MockERC20(DAI).approve(ROUTER,  type(uint256).max);

        // ── Step 3: Seed pairs ────────────────────────────────────────────
        // WETH/USDC — BlueChip tier (WETH=bluechip, USDC=stable)
        Router(ROUTER).addLiquidity(
            WETH, USDC,
            100 ether,           // 100 WETH
            200_000 * 1e6,       // 200,000 USDC  (1 WETH = 2000 USDC)
            0, 0, deployer, DEADLINE
        );
        console.log("WETH/USDC seeded");

        // WBTC/USDC — BlueChip tier
        Router(ROUTER).addLiquidity(
            WBTC, USDC,
            10 * 1e8,            // 10 WBTC
            600_000 * 1e6,       // 600,000 USDC  (1 WBTC = 60000 USDC)
            0, 0, deployer, DEADLINE
        );
        console.log("WBTC/USDC seeded");

        // ARB/USDC — BlueChip tier (ARB=bluechip, USDC=stable)
        Router(ROUTER).addLiquidity(
            ARB, USDC,
            500_000 ether,       // 500,000 ARB
            500_000 * 1e6,       // 500,000 USDC  (1 ARB = 1 USDC)
            0, 0, deployer, DEADLINE
        );
        console.log("ARB/USDC seeded");

        // DAI/USDC — Stable tier (both stable)
        Router(ROUTER).addLiquidity(
            DAI, USDC,
            100_000 ether,       // 100,000 DAI
            100_000 * 1e6,       // 100,000 USDC  (1 DAI = 1 USDC)
            0, 0, deployer, DEADLINE
        );
        console.log("DAI/USDC seeded");

        // WETH/DAI — BlueChip tier
        Router(ROUTER).addLiquidity(
            WETH, DAI,
            100 ether,           // 100 WETH
            200_000 ether,       // 200,000 DAI   (1 WETH = 2000 DAI)
            0, 0, deployer, DEADLINE
        );
        console.log("WETH/DAI seeded");

        // ── Step 4: First TWAP oracle snapshot for each pair ─────────────
        // This is snapshot #1. You must wait >= 2 hours then run
        // BootstrapOracle.s.sol to take snapshot #2 before TWAP is readable.
        address wethUsdc = Factory(FACTORY).getPair(WETH, USDC);
        address wbtcUsdc = Factory(FACTORY).getPair(WBTC, USDC);
        address arbUsdc  = Factory(FACTORY).getPair(ARB,  USDC);
        address daiUsdc  = Factory(FACTORY).getPair(DAI,  USDC);
        address wethDai  = Factory(FACTORY).getPair(WETH, DAI);

        TWAPOracle(ORACLE).update(wethUsdc);
        TWAPOracle(ORACLE).update(wbtcUsdc);
        TWAPOracle(ORACLE).update(arbUsdc);
        TWAPOracle(ORACLE).update(daiUsdc);
        TWAPOracle(ORACLE).update(wethDai);

        vm.stopBroadcast();

        console.log("\n=== LIQUIDITY SEEDED ===");
        console.log("WETH/USDC pair:", wethUsdc);
        console.log("WBTC/USDC pair:", wbtcUsdc);
        console.log("ARB/USDC pair: ", arbUsdc);
        console.log("DAI/USDC pair: ", daiUsdc);
        console.log("WETH/DAI pair: ", wethDai);
        console.log("");
        console.log("NEXT STEP: Wait >= 2 hours, then run BootstrapOracle.s.sol");
    }
}
