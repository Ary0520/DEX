// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Deploys the full VerdexSwap system in the correct order and wires
///         every contract together. Run this ONCE on a fresh chain.
///
/// Deployment order (dependency-safe):
///   1. Factory
///   2. TWAPOracle
///   3. ILShieldVault  (needs USDC address)
///   4. ILPositionManager (temp router = deployer, updated after Router deploy)
///   5. Router         (needs Factory, Vault, PM, Oracle, Treasury)
///   6. FeeConverter   (needs Factory, Vault, Oracle, USDC)
///   7. Wire: Vault.setRouter, Vault.setFeeConverter
///   8. Wire: PositionManager re-deploy with real Router address
///   9. Wire: Router.setPositionManager
///  10. Register token tiers in Factory (USDC=stable, WETH/WBTC/ARB=bluechip)

import {Script, console} from "forge-std/Script.sol";
import {Factory}           from "../src/FactoryContract.sol";
import {TWAPOracle}        from "../src/TWAPOracle.sol";
import {ILShieldVault}     from "../src/ILShieldVault.sol";
import {ILPositionManager} from "../src/ILPositionManager.sol";
import {Router}            from "../src/Router.sol";
import {FeeConverter}      from "../src/FeeConverter.sol";

contract Deploy is Script {

    // ── Token addresses (set by DeployTokens.s.sol) ───────────────────────
    // Update these after running DeployTokens first.
    address constant USDC = 0x5c55e9075386Bb76d77bed821E209fE6cac350b6;
    address constant WETH = 0x9a1eDFdcA16212683E45Fb3C285115a2668F3d10;
    address constant WBTC = 0x5140a037A1cD818a17ebFbF812D6fEf60e8dc5a8;
    address constant ARB  = 0xA52079EE2000c801A1d355d51f276b0A03F86D39;
    address constant DAI  = 0x280F784ff03772fBc82E20052bb0247d042a5b07;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address treasury    = deployer; // use deployer as treasury for testnet

        vm.startBroadcast(deployerKey);

        // ── 1. Factory ────────────────────────────────────────────────────
        Factory factory = new Factory();
        console.log("Factory:           ", address(factory));

        // ── 2. TWAP Oracle ────────────────────────────────────────────────
        TWAPOracle oracle = new TWAPOracle();
        console.log("TWAPOracle:        ", address(oracle));

        // ── 3. ILShieldVault ──────────────────────────────────────────────
        // Router address not known yet — pass deployer as placeholder,
        // will be updated via setRouter() below.
        ILShieldVault vault = new ILShieldVault(deployer, USDC);
        console.log("ILShieldVault:     ", address(vault));

        // ── 4. ILPositionManager (placeholder router = deployer) ──────────
        ILPositionManager pm = new ILPositionManager(deployer);
        console.log("ILPositionManager: ", address(pm));

        // ── 5. Router ─────────────────────────────────────────────────────
        Router router = new Router(
            address(factory),
            address(vault),
            address(pm),
            address(oracle),
            treasury
        );
        console.log("Router:            ", address(router));

        // ── 6. FeeConverter ───────────────────────────────────────────────
        FeeConverter converter = new FeeConverter(
            address(factory),
            address(vault),
            address(oracle),
            USDC
        );
        console.log("FeeConverter:      ", address(converter));

        // ── 7. Wire Vault ─────────────────────────────────────────────────
        vault.setRouter(address(router));
        vault.setFeeConverter(address(converter));

        // ── 8. Re-deploy PositionManager with real Router ─────────────────
        // The first PM had deployer as router — replace it now.
        ILPositionManager pmFinal = new ILPositionManager(address(router));
        console.log("ILPositionManager (final): ", address(pmFinal));

        // ── 9. Wire Router → final PositionManager ────────────────────────
        router.setPositionManager(address(pmFinal));

        // ── 10. Register token tiers in Factory ───────────────────────────
        // Stable tokens (both sides stable → Stable tier)
        factory.setTokenTier(USDC, true,  false);
        factory.setTokenTier(DAI,  true,  false);

        // Blue chip tokens
        factory.setTokenTier(WETH, false, true);
        factory.setTokenTier(WBTC, false, true);
        factory.setTokenTier(ARB,  false, true);

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Chain:             ", block.chainid);
        console.log("Deployer:          ", deployer);
        console.log("Treasury:          ", treasury);
        console.log("");
        console.log("--- COPY THESE INTO DeployTokens + SeedLiquidity ---");
        console.log("FACTORY:    ", address(factory));
        console.log("ORACLE:     ", address(oracle));
        console.log("VAULT:      ", address(vault));
        console.log("PM:         ", address(pmFinal));
        console.log("ROUTER:     ", address(router));
        console.log("CONVERTER:  ", address(converter));
    }
}
