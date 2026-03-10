// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Factory} from "../src/FactoryContract.sol";
import {Pair} from "../src/Pair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract FactoryTest is Test {
    Factory factory;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    address user = makeAddr("user");
    address feeReceiver = makeAddr("feeReceiver");
    address newSetter = makeAddr("newSetter");

    function setUp() public {
        factory = new Factory();
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        tokenC = new MockERC20("Token C", "TKC");
    }

    //////////////////////
    // createPair tests //
    //////////////////////

    function test_createPair_success() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertTrue(pair != address(0));
    }

    function test_createPair_storesInMapping() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        // symmetric lookup
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair);
    }

    function test_createPair_pushesToAllPairs() public {
        factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.allPairs(0) != address(0), true);
    }

    function test_createPair_emitsPairCreated() public {
        // tokens are sorted, figure out order
        (address t0, address t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        vm.expectEmit(true, true, false, false);
        emit Factory.PairCreated(t0, t1, address(0));
        factory.createPair(address(tokenA), address(tokenB));
    }

    function test_createPair_sortedTokens() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        address token0 = Pair(pair).token0();
        address token1 = Pair(pair).token1();
        // token0 < token1
        assertTrue(token0 < token1);
    }

    function test_createPair_revertsOnIdenticalTokens() public {
        vm.expectRevert(Factory.DEX__IdenticalTokens.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_createPair_revertsOnZeroAddress() public {
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.createPair(address(0), address(tokenB));
    }

    function test_createPair_revertsOnZeroAddressB() public {
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.createPair(address(tokenA), address(0));
    }

    function test_createPair_revertsIfAlreadyExists() public {
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(Factory.DEX__PairAlreadyExists.selector);
        factory.createPair(address(tokenA), address(tokenB));
    }

    function test_createPair_revertsIfAlreadyExistsReversed() public {
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(Factory.DEX__PairAlreadyExists.selector);
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_createPair_multiplePairs() public {
        factory.createPair(address(tokenA), address(tokenB));
        factory.createPair(address(tokenA), address(tokenC));
        factory.createPair(address(tokenB), address(tokenC));
        // all three distinct
        assertTrue(factory.allPairs(0) != factory.allPairs(1));
        assertTrue(factory.allPairs(1) != factory.allPairs(2));
    }

    ////////////////////
    // setFeeTo tests //
    ////////////////////

    function test_setFeeTo_success() public {
        factory.setFeeTo(feeReceiver);
        assertEq(factory.feeTo(), feeReceiver);
    }

    function test_setFeeTo_revertsIfNotSetter() public {
        vm.prank(user);
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setFeeTo(feeReceiver);
    }

    function test_setFeeTo_canSetToZero() public {
        factory.setFeeTo(feeReceiver);
        factory.setFeeTo(address(0)); // allowed - disables fee
        assertEq(factory.feeTo(), address(0));
    }

    //////////////////////////
    // setFeeToSetter tests //
    //////////////////////////

    function test_setFeeToSetter_success() public {
        factory.setFeeToSetter(newSetter);
        assertEq(factory.feeToSetter(), newSetter);
    }

    function test_setFeeToSetter_revertsIfNotSetter() public {
        vm.prank(user);
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setFeeToSetter(newSetter);
    }

    function test_setFeeToSetter_revertsOnZeroAddress() public {
        vm.expectRevert(Factory.DEX__ZeroAddress.selector);
        factory.setFeeToSetter(address(0));
    }

    function test_setFeeToSetter_oldSetterLosesAccess() public {
        factory.setFeeToSetter(newSetter);
        // original deployer no longer has access
        vm.expectRevert(Factory.DEX__Forbidden.selector);
        factory.setFeeTo(feeReceiver);
    }

    function test_setFeeToSetter_newSetterCanAct() public {
        factory.setFeeToSetter(newSetter);
        vm.prank(newSetter);
        factory.setFeeTo(feeReceiver);
        assertEq(factory.feeTo(), feeReceiver);
    }

    /////////////////////
    // constructor test //
    /////////////////////

    function test_constructor_setsFeeToSetter() public view {
        assertEq(factory.feeToSetter(), address(this));
    }

    function test_constructor_feeToIsZero() public view {
        assertEq(factory.feeTo(), address(0));
    }
}
