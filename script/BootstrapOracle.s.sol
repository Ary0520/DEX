// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Takes the SECOND TWAP oracle snapshot for all pairs.
///         Run this >= 2 hours after SeedLiquidity.s.sol.
///
///         After this runs, TWAP is live and FeeConverter can operate.
///         The frontend can also start showing TWAP-based prices.

import {Script, console} from "forge-std/Script.sol";
import {TWAPOracle}       from "../src/TWAPOracle.sol";
import {Factory}          from "../src/FactoryContract.sol";

contract BootstrapOracle is Script {

    // ── Paste from Deploy.s.sol output ────────────────────────────────────
    address constant FACTORY = 0x0000000000000000000000000000000000000001; // TODO
    address constant ORACLE  = 0x0000000000000000000000000000000000000002; // TODO

    // ── Paste from DeployTokens.s.sol output ──────────────────────────────
    address constant USDC    = 0x0000000000000000000000000000000000000003; // TODO
    address constant WETH    = 0x0000000000000000000000000000000000000004; // TODO
    address constant WBTC    = 0x0000000000000000000000000000000000000005; // TODO
    address constant ARB     = 0x0000000000000000000000000000000000000006; // TODO
    address constant DAI     = 0x0000000000000000000000000000000000000007; // TODO

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        address wethUsdc = Factory(FACTORY).getPair(WETH, USDC);
        address wbtcUsdc = Factory(FACTORY).getPair(WBTC, USDC);
        address arbUsdc  = Factory(FACTORY).getPair(ARB,  USDC);
        address daiUsdc  = Factory(FACTORY).getPair(DAI,  USDC);
        address wethDai  = Factory(FACTORY).getPair(WETH, DAI);

        TWAPOracle(ORACLE).update(wethUsdc);
        console.log("WETH/USDC oracle updated");

        TWAPOracle(ORACLE).update(wbtcUsdc);
        console.log("WBTC/USDC oracle updated");

        TWAPOracle(ORACLE).update(arbUsdc);
        console.log("ARB/USDC oracle updated");

        TWAPOracle(ORACLE).update(daiUsdc);
        console.log("DAI/USDC oracle updated");

        TWAPOracle(ORACLE).update(wethDai);
        console.log("WETH/DAI oracle updated");

        vm.stopBroadcast();

        console.log("\n=== ORACLE BOOTSTRAPPED ===");
        console.log("TWAP is now live. Wait >= 30 minutes before first FeeConverter call.");
        console.log("Frontend can now read TWAP prices.");
    }
}
