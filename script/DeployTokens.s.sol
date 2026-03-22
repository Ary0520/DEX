// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract DeployTokens is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        MockERC20 weth = new MockERC20("Wrapped Ether",   "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin",        "USDC", 6);
        MockERC20 dai  = new MockERC20("Dai Stablecoin",  "DAI",  18);
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        MockERC20 arb  = new MockERC20("Arbitrum",        "ARB",  18);

        vm.stopBroadcast();

        console.log("--- SAVE THESE TOKEN ADDRESSES ---");
        console.log("WETH:", address(weth));
        console.log("USDC:", address(usdc));
        console.log("DAI: ", address(dai));
        console.log("WBTC:", address(wbtc));
        console.log("ARB: ", address(arb));
    }
}