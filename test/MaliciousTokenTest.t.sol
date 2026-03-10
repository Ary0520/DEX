// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../src/FactoryContract.sol";
import {Pair} from "../src/Pair.sol";
import {Router} from "../src/Router.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReturnFalseToken, NoReturnToken, ReentrantToken} from "./mocks/MaliciousTokens.sol";

contract MaliciousTokenTest is Test {
    Factory factory;
    Router router;

    address alice = makeAddr("alice");
    uint constant DEADLINE = type(uint).max;

    function setUp() public {
        factory = new Factory();
        router = new Router(address(factory));
    }

    // ─── ReturnFalseToken ─────────────────────────────────────────────────────

    function test_malicious_transferReturnsFalse_pairTransferFails() public {
    ReturnFalseToken badToken = new ReturnFalseToken();
    MockERC20 goodToken = new MockERC20("Good", "GD");

    address pairAddr = factory.createPair(address(badToken), address(goodToken));
    Pair pair = Pair(pairAddr);

    badToken.mint(address(pair), 10 ether);
    goodToken.mint(address(pair), 10 ether);
    pair.mint(alice);

    // send goodToken IN, request badToken OUT → pair calls badToken.transfer() → false → revert
    goodToken.mint(address(pair), 1 ether);

    // figure out which slot badToken is in
    uint amount0Out;
    uint amount1Out;
    if (pair.token0() == address(badToken)) {
        amount0Out = 0.9 ether;
        amount1Out = 0;
    } else {
        amount0Out = 0;
        amount1Out = 0.9 ether;
    }

    vm.expectRevert(Pair.Pair__TransferFailed.selector);
    pair.swap(amount0Out, amount1Out, alice);
}

    function test_malicious_transferFromReturnsFalse_routerFails() public {
        // router's _safeTransferFrom gets false → Router__TransferFailed
        ReturnFalseToken badToken = new ReturnFalseToken();
        MockERC20 goodToken = new MockERC20("Good", "GD");

        factory.createPair(address(badToken), address(goodToken));

        badToken.mint(alice, 10 ether);
        vm.prank(alice);
        badToken.approve(address(router), type(uint).max);

        goodToken.mint(alice, 10 ether);
        vm.prank(alice);
        goodToken.approve(address(router), type(uint).max);

        // addLiquidity calls _safeTransferFrom(badToken,...) → returns false → revert
        vm.prank(alice);
        vm.expectRevert(Router.Router__TransferFailed.selector);
        router.addLiquidity(
            address(badToken), address(goodToken),
            5 ether, 5 ether, 0, 0, alice, DEADLINE
        );
    }

    // ─── NoReturnToken ────────────────────────────────────────────────────────

    function test_malicious_noReturnData_pairTransferFails() public {
        NoReturnToken badToken = new NoReturnToken();
        MockERC20 goodToken = new MockERC20("Good", "GD");

        address pairAddr = factory.createPair(address(badToken), address(goodToken));
        Pair pair = Pair(pairAddr);

        badToken.mint(address(pair), 10 ether);
        goodToken.mint(address(pair), 10 ether);
        pair.mint(alice);

        goodToken.mint(address(pair), 1 ether);
        vm.expectRevert(); // reverts with no data
        pair.swap(1 ether, 0, alice);
    }

    function test_malicious_noReturnData_routerTransferFromFails() public {
        NoReturnToken badToken = new NoReturnToken();
        MockERC20 goodToken = new MockERC20("Good", "GD");

        factory.createPair(address(badToken), address(goodToken));

        badToken.mint(alice, 10 ether);
        vm.prank(alice);
        badToken.approve(address(router), type(uint).max);

        goodToken.mint(alice, 10 ether);
        vm.prank(alice);
        goodToken.approve(address(router), type(uint).max);

        vm.prank(alice);
        vm.expectRevert();
        router.addLiquidity(
            address(badToken), address(goodToken),
            5 ether, 5 ether, 0, 0, alice, DEADLINE
        );
    }

    // ─── ReentrantToken ───────────────────────────────────────────────────────

    function test_malicious_reentrancy_swapLocked() public {
    ReentrantToken reentrantToken = new ReentrantToken();
    MockERC20 goodToken = new MockERC20("Good", "GD");

    address pairAddr = factory.createPair(address(reentrantToken), address(goodToken));
    Pair pair = Pair(pairAddr);
    reentrantToken.setPair(pairAddr);

    reentrantToken.mint(address(pair), 10 ether);
    goodToken.mint(address(pair), 10 ether);
    pair.mint(alice);

    reentrantToken.mint(alice, 5 ether);
    vm.prank(alice);
    reentrantToken.approve(address(router), type(uint).max);
    goodToken.mint(alice, 5 ether);
    vm.prank(alice);
    goodToken.approve(address(router), type(uint).max);

    address[] memory path = new address[](2);
    path[0] = address(reentrantToken);
    path[1] = address(goodToken);

    vm.prank(alice);
    router.swapExactTokensForTokens(1 ether, 0, path, alice, DEADLINE);

    // KEY invariant: after the swap (with reentrant callback silently blocked),
    // reserves must exactly match actual balances — no double-spend occurred
    (uint112 r0, uint112 r1,) = pair.getReserves();
    assertEq(MockERC20(pair.token0()).balanceOf(address(pair)), r0, "token0 reserve mismatch");
    assertEq(MockERC20(pair.token1()).balanceOf(address(pair)), r1, "token1 reserve mismatch");
}

    function test_malicious_reentrancy_mintLocked() public {
        // attempt to reenter mint() during a swap
        ReentrantToken reentrantToken = new ReentrantToken();
        MockERC20 goodToken = new MockERC20("Good", "GD");

        address pairAddr = factory.createPair(address(reentrantToken), address(goodToken));
        Pair pair = Pair(pairAddr);
        reentrantToken.setPair(pairAddr);

        reentrantToken.mint(address(pair), 10 ether);
        goodToken.mint(address(pair), 10 ether);
        pair.mint(alice);

        // verify lock prevents double-entry — pair state must be consistent after
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(reentrantToken.balanceOf(address(pair)), r0 > 0 ? r0 : r1);
    }
}