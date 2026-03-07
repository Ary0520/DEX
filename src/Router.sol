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
    error Router__SlippageExceeded();
    error Router__TransferFailed();
    error Router__AmountZero();

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

    function _safeTransferFrom(address token, address from, address to, uint amount) internal {
        (bool success, bytes memory data) =
            token.call(
                abi.encodeWithSelector(
                    IERC20.transferFrom.selector,
                    from,
                    to,
                    amount
                )
            );

    if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
        revert Router__TransferFailed();
    }
}

    function _quote(uint amountA, uint reserveA, uint reserveB) internal pure returns(uint amountB){
        if(reserveA == 0|| reserveB == 0){
            revert Router__PairNotFound();
        }
        //if pair exists->
        amountB = (amountA * reserveB)/reserveA;
    }

    //*internal* _addliquidity
    function _addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin) internal returns(uint amountA, uint amountB){

        address pair = IFactory(factory).getPair(tokenA, tokenB);
        if(pair == address(0)){ //create that new pair
            IFactory(factory).createPair(tokenA, tokenB);
        }
        pair = IFactory(factory).getPair(tokenA, tokenB); //fetch again

        //fetch reserves->
        (uint reserve0, uint reserve1, ) = IPair(pair).getReserves();

        //pair stores sorted tokens, so arrange reserves0/1 according to that->
        address token0 = IPair(pair).token0();
        // address token1 = IPair(pair).token1();

        uint reserveA;
        uint reserveB;

        if(tokenA == token0){
            reserveA = reserve0;
            reserveB = reserve1;
        }else{
            reserveA = reserve1;
            reserveB = reserve0;
        }

        //if pool= empty->
        if(reserveA == 0 && reserveB == 0){
            amountA = amountADesired;
            amountB = amountBDesired;
        }else{
            uint amountBOptimal = _quote(amountADesired, reserveA, reserveB);
            if(amountBOptimal <= amountBDesired){
                amountA = amountADesired;
                amountB = amountBOptimal;
            }else{
                uint amountAoptimal= _quote(amountBDesired, reserveB, reserveA);
                amountA = amountAoptimal;
                amountB = amountBDesired;
            }
        }

        //slippage protection->
        if(amountA < amountAMin || amountB < amountBMin ){
            revert Router__SlippageExceeded();
        }

    }

    //external addliquidity(callable by user)->
    function addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin, address to, uint deadline) external ensure(deadline) returns(uint amountA, uint amountB, uint liquidity){

        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = IFactory(factory).getPair(tokenA, tokenB);

        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);

        liquidity = IPair(pair).mint(to);
        return(amountA, amountB, liquidity);

    }

    //*internal _remove liquidity
    function _removeLiquidity(address tokenA, address tokenB, uint liquidity, uint amountAMin, uint amountBMin, address to) internal returns(uint amountA, uint amountB){
        address pair = IFactory(factory).getPair(tokenA, tokenB);
        if(pair == address(0)){
            revert Router__PairNotFound();
        }
        _safeTransferFrom(pair, msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = IPair(pair).burn(to);

        address token0 = IPair(pair).token0();        
        if(tokenA == token0){
            amountA = amount0;
            amountB = amount1;

        }else{
            amountA = amount1;
            amountB = amount0;
        }

        //slippage protection->
        if(amountA < amountAMin){
            revert Router__SlippageExceeded();
        }
        if(amountB < amountBMin){
            revert Router__SlippageExceeded();
        }

        return(amountA, amountB);
    }

    //external removeliquidity(callable by user)->
    function removeLiquidity(address tokenA, address tokenB, uint liquidity, uint amountAMin, uint amountBMin, address to, uint deadline) external ensure(deadline) returns(uint amountA, uint amountB){    
        
        (amountA, amountB) = _removeLiquidity(
        tokenA,
        tokenB,
        liquidity,
        amountAMin,
        amountBMin,
        to
        );
        return(amountA, amountB);

    }

    //(internal helper fn) compute output for one pair
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns(uint amountOut){
        if(amountIn== 0){
            revert Router__AmountZero();
        }
        if( reserveIn == 0 || reserveOut == 0){
            revert Router__PairNotFound();
        }

        uint amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);

        return(amountOut);
    }

    //computer for multiple pairs
    function getAmountsOut(uint amountIn, address[] memory path) internal view returns(uint[] memory amounts){
        amounts = new uint[](path.length);

        //first element is the input itself
        amounts[0] = amountIn;

        for(uint i = 0; i<path.length -1; i++){
            address pair = IFactory(factory).getPair(path[i], path[i+1]);
            if(pair == address(0)){
                revert Router__PairNotFound();
            }
            (uint reserve0, uint reserve1,) = IPair(pair).getReserves();
            address token0 = IPair(pair).token0();

            uint reserveIn;
            uint reserveOut;

            if (path[i] == token0) {
                reserveIn = reserve0;
                reserveOut = reserve1;
            } else {
                reserveIn = reserve1;
                reserveOut = reserve0;
            }

            amounts[i+1] = getAmountOut(amounts[i], reserveIn, reserveOut);

        }
        
    }

    function _swap(uint[] memory amounts, address[] memory path, address _to)internal{

        for (uint i = 0; i < path.length - 1; i++) {

            address input = path[i];
            address output = path[i + 1];

            address pair = IFactory(factory).getPair(input, output);

            address token0 = IPair(pair).token0();

            uint amountOut = amounts[i + 1];

            uint amount0Out;
            uint amount1Out;

            if (input == token0) {
                amount0Out = 0;
                amount1Out = amountOut;
            } else {
                amount0Out = amountOut;
                amount1Out = 0;
            }

            address to;

            if (i < path.length - 2) {
                to = IFactory(factory).getPair(output, path[i + 2]);
            } else {
                to = _to;
            }

            IPair(pair).swap(amount0Out, amount1Out, to);
        }   

    }

    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external ensure(deadline) returns (uint[] memory amounts){

        amounts = getAmountsOut(amountIn, path);

        if (amounts[amounts.length - 1] < amountOutMin) {
            revert Router__SlippageExceeded();
        }

        address pair = IFactory(factory).getPair(path[0], path[1]);
        _safeTransferFrom(path[0], msg.sender, pair, amounts[0]);
        _swap(amounts, path, to);
        return amounts;

    }
}