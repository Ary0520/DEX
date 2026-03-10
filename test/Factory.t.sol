// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/FactoryContract.sol";
import "../src/Pair.sol";

import "./mocks/MockERC20.sol";

contract FactoryTest is Test {

    Factory factory;

    MockERC20 tokenA;
    MockERC20 tokenB;

    function setUp() public {

        factory = new Factory();

        tokenA = new MockERC20("TokenA","A");
        tokenB = new MockERC20("TokenB","B");
    }

    function testCreatePair() public {

        factory.createPair(address(tokenA), address(tokenB));

        address pair = factory.getPair(address(tokenA), address(tokenB));

        assertTrue(pair != address(0));
    }

    function testCannotCreateDuplicatePair() public {

        factory.createPair(address(tokenA), address(tokenB));

        vm.expectRevert();

        factory.createPair(address(tokenA), address(tokenB));
    }

    function testCannotCreatePairWithIdenticalTokens() public {

        vm.expectRevert();

        factory.createPair(address(tokenA), address(tokenA));
    }
}