// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Pair contract
/// @author AryyyInLoop
/// @notice a pair contract: - hold token reserves, handles swaps, mint LP tokens, track liquidity.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Pair{
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 blockTimestampLast;

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

    function getReserves() external view returns(uint112 _reserve0, uint112 _reserve1, uint32 timestamp){
        return (reserve0, reserve1, blockTimestampLast);
    }

    function _update() internal{
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        require(balance0 <= type(uint112).max, "OVERFLOW");
        require(balance1 <= type(uint112).max, "OVERFLOW");
        
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);
    }
}