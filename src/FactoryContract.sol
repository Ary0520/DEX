// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pair} from "./Pair.sol";

contract Factory{

    address public feeTo;
    address public feeToSetter;

    error DEX__IdenticalTokens();
    error DEX__ZeroAddress();
    error DEX__PairAlreadyExists();
    error DEX__Forbidden();

    event PairCreated(address indexed token0, address indexed token1, address pairAddress);
    
    mapping(address token0 => mapping(address token1 => address)) public getPair;

    address[] public allPairs; //array of all pairs

    constructor(){
        feeToSetter = msg.sender;
    }

    ///////////////
    //functions->//
    ///////////////
    function createPair(address tokenA, address tokenB) external returns (address pair){
        if(tokenA == tokenB){
            revert DEX__IdenticalTokens();
        }
        if(tokenA == address(0) || tokenB == address(0)){
            revert DEX__ZeroAddress();
        }
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        if(getPair[token0][token1] != address(0)){
            revert DEX__PairAlreadyExists();
        }
        //deploy and initalize new pair contract->
        Pair _pair = new Pair();
        _pair.initialize(token0, token1);

        pair = address(_pair);
        //store pair in the mapping->
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair);
        
    }

    function setFeeTo(address newFeeTo) external {
        if(msg.sender != feeToSetter){
            revert DEX__Forbidden();
        }
        feeTo = newFeeTo;
    }

    function setFeeToSetter(address newSetter) external{
        if(msg.sender != feeToSetter){
            revert DEX__Forbidden();
        }
        if(newSetter == address(0)){
            revert DEX__ZeroAddress();
        }
        feeToSetter = newSetter;
    }
    
}