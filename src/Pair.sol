// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Pair contract
/// @author AryyyInLoop
/// @notice a pair contract: - hold token reserves, handles swaps, mint LP tokens, track liquidity.


contract Pair{
    address public factory;
    address public token0;
    address public token1;

    error Pair__Forbidden();
    error Pair__AlreadyInitialized();

    bool isAlreadyInitialized;

    constructor(){
        factory = msg.sender;
    }

    /////////////
    //functions//
    /////////////
    function initialize(address _token0, address _token1) external{
        if(msg.sender !=factory){
            revert Pair__Forbidden();
        }
        if(isAlreadyInitialized == true){
            revert Pair__AlreadyInitialized();
        }

        token0 = _token0;
        token1 = _token1;
        isAlreadyInitialized = true;
    }
}