// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Pair contract
/// @author AryyyInLoop
/// @notice a pair contract: - hold token reserves, handles swaps, mint LP tokens, track liquidity.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Pair is ERC20 {
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 blockTimestampLast;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    

    error Pair__Forbidden();
    error Pair__AlreadyInitialized();
    error Pair__InsufficientLiquidityMinted();
    error Pair__AmountZero();
    error Pair__TransferFailed();
    error Pair__ZeroTotalSupply();
    error Pair__InsufficientOutputAmount();

    bool isAlreadyInitialized;

    constructor() ERC20("LP-TOKEN", "LP"){
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

    function _safeTransfer(address token, address to, uint amount) internal{
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));

        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert Pair__TransferFailed();
        }
    }

    function mint(address to) external returns(uint _liquidity){
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        require(balance0 <= type(uint112).max, "OVERFLOW");
        require(balance1 <= type(uint112).max, "OVERFLOW");

        uint112 oldReserve0 = reserve0;
        uint112 oldReserve1 = reserve1;

        uint256 amount0 = balance0 - oldReserve0;
        uint256 amount1 = balance1 - oldReserve1;

        require(amount0 > 0 && amount1 > 0, "Amount must be more than zero");

        uint256 liquidity;
        uint256 _totalSupply = totalSupply();

        if(_totalSupply == 0){
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            if(liquidity <= 0){
                revert Pair__InsufficientLiquidityMinted();
            }else{
                _mint(address(0), MINIMUM_LIQUIDITY); //protects the protocol
                _mint(to, liquidity);
            }
        }else{ //liquidity already exists in pool
            require(oldReserve0 > 0 && oldReserve1 > 0, "zero reserves!");

            uint liquidity0 = (amount0 * _totalSupply)/oldReserve0;
            uint liquidity1 = (amount1 * _totalSupply)/oldReserve1;

            liquidity = Math.min(liquidity0, liquidity1);
            if(liquidity <= 0){
                revert Pair__InsufficientLiquidityMinted();
            }else{
                _mint(to, liquidity);
            }
        }

        _update();
        return liquidity;
    }

    function burn(address to) external returns(uint _amount0, uint _amount1){
        uint liquidity = balanceOf(address(this)); //since contract itself is lptoken
        if(liquidity == 0){
            revert Pair__AmountZero();
        }
        address _token0 = token0;
        address _token1 = token1;

        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint _totalSupply = totalSupply();
        if(_totalSupply == 0){
            revert Pair__ZeroTotalSupply();
        }

        uint amount0;
        uint amount1;
        amount0 = (liquidity * balance0)/_totalSupply;
        amount1 = (liquidity * balance1)/_totalSupply;

        if(amount0 == 0 || amount1 == 0){
            revert Pair__AmountZero();
        }else{
            _burn(address(this), liquidity); //burn LP token first, prevent reentrancy
            _safeTransfer(_token0, to, amount0);
            _safeTransfer(_token1, to, amount1);

            _update();
            return(amount0, amount1);
        }
    }

    function swap(uint amount0Out, uint amount1Out, address to)external{
        if(amount0Out == 0 && amount1Out == 0){
            revert Pair__InsufficientOutputAmount();
        }
        if(amount0Out > 0 && amount1Out > 0){
            revert Pair__Forbidden();
        }
        uint112 _reserve0 = reserve0;
        uint112 _reserve1 = reserve1;
        address _token0 = token0;
        address _token1 = token1;

        if(amount0Out > _reserve0 || amount1Out > _reserve1){
            revert Pair__Forbidden();
        }
        if(amount0Out > 0){
            _safeTransfer(_token0, to, amount0Out);
        }
        if(amount1Out>0){
            _safeTransfer(_token1, to, amount1Out);
        }
        
    }
}