// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Deploys mock ERC20 tokens for testnet use.
///         Run this BEFORE Deploy.s.sol, then paste the addresses into Deploy.s.sol.
///
///         On testnet, mock tokens are correct and standard practice.
///         Real USDC/WETH do not exist reliably on Arbitrum Sepolia.

import {Script, console} from "forge-std/Script.sol";
import {MockERC20}        from "../test/mocks/MockERC20.sol";

contract DeployTokens is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockERC20 usdc = new MockERC20("USD Coin",        "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether",   "WETH", 18);
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        MockERC20 arb  = new MockERC20("Arbitrum",        "ARB",  18);
        MockERC20 dai  = new MockERC20("Dai Stablecoin",  "DAI",  18);

        vm.stopBroadcast();

        console.log("=== TOKEN ADDRESSES - paste into Deploy.s.sol ===");
        console.log("USDC:", address(usdc));
        console.log("WETH:", address(weth));
        console.log("WBTC:", address(wbtc));
        console.log("ARB: ", address(arb));
        console.log("DAI: ", address(dai));
        console.log("Deployer:", deployer);
    }
}
