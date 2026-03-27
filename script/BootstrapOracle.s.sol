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
    address constant FACTORY = 0x23942d68C74f80cE259a4dA31a59856fFde5425e;
    address constant ORACLE  = 0xA18F7Bd8be9611fD8499C15e0BC6aa9C4c0eF268;

    // ── Paste from DeployTokens.s.sol output ──────────────────────────────
    address constant USDC    = 0x98697D7bc9ea50CE6682ed52CBC95806E7fDee0f;
    address constant WETH    = 0x11dA2D696ddA3E569608F7E802F7CfD5BBe89d4b;
    address constant WBTC    = 0xFeD51c995304775D37C54a7197a9197150147E3b;
    address constant ARB     = 0xC4999f55d2887d003d17Dc42625354fA364c29D1;
    address constant DAI     = 0x9e3b254cAdC9eaeFa80fD85F26Eb7BbBE1F59560;

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
