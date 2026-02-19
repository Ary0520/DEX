// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Factory{

    address public feeTo;
    address public feeToSetter;

    error DEX__IdenticalTokens();
    error DEX__ZeroAddress();
    error DEX__PairAlreadyExists();

    event PairCreated(address indexed token0, address indexed token1, address pairAddress);
    
    mapping(address tokenA => mapping(address tokenB => address)) public getPair;

    address[] public allPairs; //array of all pairs

    function createPair(address tokenA, address tokenB) external{
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
    }

}