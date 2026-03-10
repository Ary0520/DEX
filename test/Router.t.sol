// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/FactoryContract.sol";
import "../src/Router.sol";

import "./mocks/MockERC20.sol";

contract RouterTest is Test {

    Factory factory;
    Router router;

    MockERC20 tokenA;
    MockERC20 tokenB;

    address user = address(1);

    function setUp() public {

        factory = new Factory();
        router = new Router(address(factory));

        tokenA = new MockERC20("TokenA","A");
        tokenB = new MockERC20("TokenB","B");

        tokenA.mint(user, 1000 ether);
        tokenB.mint(user, 1000 ether);

        vm.startPrank(user);

        tokenA.approve(address(router), type(uint).max);
        tokenB.approve(address(router), type(uint).max);

        vm.stopPrank();
    }

    function testAddLiquidityRouter() public {

        vm.startPrank(user);

        router.addLiquidity(
            address(tokenA),
            address(tokenB),
            10 ether,
            10 ether,
            0,
            0,
            user,
            block.timestamp
        );

        vm.stopPrank();
    }
}