

// import {Script, console} from "forge-std/Script.sol";
// import {Factory} from "../src/FactoryContract.sol";
// import {Router} from "../src/Router.sol";

// contract DeployDEX is Script {
//     function run() external {
//         uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
//         address deployer = vm.addr(deployerPrivateKey);

//         console.log("Deploying from:", deployer);
//         console.log("Balance:", deployer.balance);

//         vm.startBroadcast(deployerPrivateKey);

//         // 1. Deploy Factory
//         Factory factory = new Factory();
//         console.log("Factory deployed at:", address(factory));

//         // 2. Deploy Router (needs factory address)
//         Router router = new Router(address(factory));
//         console.log("Router deployed at:", address(router));

//         vm.stopBroadcast();

//         console.log("\n--- SAVE THESE ADDRESSES ---");
//         console.log("Factory:", address(factory));
//         console.log("Router: ", address(router));
//     }
// }       
// SINCE I UPDATED ROUTER, HERE IS NEW SCRIPT TO DEPLOY **ONNLY** THE NEW ROUTER
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Router} from "../src/Router.sol";

contract DeployRouter is Script {

    address constant FACTORY = 0xf290c44B751262230Fb3737AbF6219199AF92f37;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying from:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        Router router = new Router(FACTORY);

        console.log("Router deployed at:", address(router));

        vm.stopBroadcast();

        console.log("\n--- SAVE THIS ADDRESS ---");
        console.log("Router:", address(router));
    }
}