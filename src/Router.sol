// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Router Contract
/// @author AryyyInLoop
/// @notice Router is responsible for:Moving tokens from user→pair, slippage protection, etc.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}
interface IPair {
    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract Router{
    address public immutable factory;

    error Router__Expired();
    error Router__ZeroAddress();
    error Router__PairNotFound();

    constructor(address _factory){
        if(_factory == address(0)){
            revert Router__ZeroAddress();
        }
        factory = _factory;
    }

    modifier ensure(uint deadline){
        if(block.timestamp > deadline){
            revert Router__Expired();
        }
        _;
    }

    //////////////
    //functions///
    //////////////

    function _quote(uint amountA, uint reserveA, uint reserveB) internal pure returns(uint amountB){
        if(reserveA == 0|| reserveB == 0){
            revert Router__PairNotFound();
        }
        //if pair exists->
        amountB = (amountA * reserveB)/reserveA;
    }

    function _addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin) internal returns(uint amountA, uint amountB){

        address pair = IFactory(factory).getPair(tokenA, tokenB);
        if(pair == address(0)){ //create that new pair
            IFactory(factory).createPair(tokenA, tokenB);
        }
        pair = IFactory(factory).getPair(tokenA, tokenB); //fetch again

        (uint reserve0, uint reserve1, ) = IPair(pair).getReserves();
        //pair stores sorted tokens, so arrange reserves0/1 according to that->
        address token0 = IPair(pair).token0();
        address token1 = IPair(pair).token1();
        if(tokenA == token0){
            
        }
    }

}