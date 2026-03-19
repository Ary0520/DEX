// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Router} from "../src/Router.sol";

contract SeedLiquidity is Script {

    // deployed addresses
    address constant ROUTER   = 0xc00416cbdC7268A5Cb599382F05dE9adeE5A2EC1;
    address constant WETH     = 0x9a1eDFdcA16212683E45Fb3C285115a2668F3d10;
    address constant USDC     = 0x5c55e9075386Bb76d77bed821E209fE6cac350b6;
    address constant DAI      = 0x280F784ff03772fBc82E20052bb0247d042a5b07;
    address constant WBTC     = 0x5140a037A1cD818a17ebFbF812D6fEf60e8dc5a8;
    address constant ARB      = 0xA52079EE2000c801A1d355d51f276b0A03F86D39;

    uint constant DEADLINE = type(uint).max;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ── Step 1: Mint tokens to yourself ──────────────────────────────────
        // Using realistic price ratios so the DEX prices make sense:
        // 1 WETH = 2000 USDC
        // 1 WETH = 2000 DAI
        // 1 WBTC = 60000 USDC (so 1 WBTC = 30 WETH)
        // 1 ARB  = 1 USDC (roughly)

        MockERC20(WETH).mint(deployer, 1_000 ether);
        MockERC20(USDC).mint(deployer, 4_000_000 ether);  // 2000 per WETH, covers multiple pairs
        MockERC20(DAI).mint(deployer,  2_000_000 ether);
        MockERC20(WBTC).mint(deployer, 50 ether);         // 50 WBTC
        MockERC20(ARB).mint(deployer, 1_000_000 ether); // was 500_000, now 1_000_000

        // ── Step 2: Approve router to spend everything ────────────────────────
        MockERC20(WETH).approve(ROUTER, type(uint).max);
        MockERC20(USDC).approve(ROUTER, type(uint).max);
        MockERC20(DAI).approve(ROUTER,  type(uint).max);
        MockERC20(WBTC).approve(ROUTER, type(uint).max);
        MockERC20(ARB).approve(ROUTER,  type(uint).max);

        // ── Step 3: Seed pairs with realistic ratios ──────────────────────────

        // WETH/USDC — 1 WETH = 2000 USDC
        Router(ROUTER).addLiquidity(
            WETH, USDC,
            100 ether,          // 100 WETH
            200_000 ether,      // 200,000 USDC
            0, 0, deployer, DEADLINE
        );
        console.log("WETH/USDC pool seeded");

        // WETH/DAI — 1 WETH = 2000 DAI
        Router(ROUTER).addLiquidity(
            WETH, DAI,
            100 ether,          // 100 WETH
            200_000 ether,      // 200,000 DAI
            0, 0, deployer, DEADLINE
        );
        console.log("WETH/DAI pool seeded");

        // WBTC/USDC — 1 WBTC = 60,000 USDC
        Router(ROUTER).addLiquidity(
            WBTC, USDC,
            10 ether,           // 10 WBTC
            600_000 ether,      // 600,000 USDC — mint more USDC above if needed
            0, 0, deployer, DEADLINE
        );
        console.log("WBTC/USDC pool seeded");

        // ARB/USDC — 1 ARB = 1 USDC
        Router(ROUTER).addLiquidity(
            ARB, USDC,
            500_000 ether,      // 500,000 ARB
            500_000 ether,      // 500,000 USDC
            0, 0, deployer, DEADLINE
        );
        console.log("ARB/USDC pool seeded");

        // WETH/ARB — 1 WETH = 2000 ARB
        Router(ROUTER).addLiquidity(
            WETH, ARB,
            50 ether,           // 50 WETH
            100_000 ether,      // 100,000 ARB
            0, 0, deployer, DEADLINE
        );
        console.log("WETH/ARB pool seeded");

        vm.stopBroadcast();

        console.log("\n--- ALL POOLS SEEDED ---");
        console.log("Deployer:", deployer);
    }
}