// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/FactoryContract.sol";
import "../src/Pair.sol";

import "./mocks/MockERC20.sol";

contract PairTest is Test {

    Factory factory;
    Pair pair;

    MockERC20 token0;
    MockERC20 token1;

    address user = address(1);

    function setUp() public {

        factory = new Factory();

        token0 = new MockERC20("Token0","T0");
        token1 = new MockERC20("Token1","T1");

        factory.createPair(address(token0), address(token1));

        address pairAddr = factory.getPair(address(token0), address(token1));

        pair = Pair(pairAddr);

        token0.mint(user, 1e24);
        token1.mint(user, 1e24);
    }

    function testAddLiquidity() public {

        vm.startPrank(user);

        token0.transfer(address(pair), 10 ether);
        token1.transfer(address(pair), 10 ether);

        uint liquidity = pair.mint(user);

        assertTrue(liquidity > 0);

        vm.stopPrank();
    }

    function testSwap() public {

        vm.startPrank(user);

        token0.transfer(address(pair), 10 ether);
        token1.transfer(address(pair), 10 ether);

        pair.mint(user);

        token0.transfer(address(pair), 1 ether);

        pair.swap(0, 0.9 ether, user);

        vm.stopPrank();
    }
}