// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Pair contract
/// @author AryyyInLoop
/// @notice a pair contract: - hold token reserves, handles swaps, mint LP tokens, track liquidity.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFactory {
    function feeTo() external view returns (address);
}

contract Pair is ERC20 {
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 blockTimestampLast;

    //for twap oracle->
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    uint public kLast;    

    error Pair__Forbidden();
    error Pair__AlreadyInitialized();
    error Pair__InsufficientLiquidityMinted();
    error Pair__AmountZero();
    error Pair__TransferFailed();
    error Pair__ZeroTotalSupply();
    error Pair__InsufficientOutputAmount();
    error Pair__InvariantViolation();
    error Pair__InvalidAddress();
    error Pair__Locked();
    error Pair__Overflow();
    error Pair__AmountMustBeMoreThanZero();
    error Pair__ZeroReserves();

    bool isAlreadyInitialized;

    constructor() ERC20("LP-TOKEN", "LP"){
        factory = msg.sender;
    }

    //protecting with reentrancy->
    uint private unlocked = 1; //locked means 0
    modifier lock(){
        if(unlocked != 1){ //if function is locked
            revert Pair__Locked();
        }
        unlocked = 0; //lock the function
        _; //function runs here
        unlocked =1 ;
    }

    //events
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

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

        if (_token0 == address(0) || _token1 == address(0)) revert Pair__InvalidAddress();
        if (_token0 == _token1) revert Pair__InvalidAddress();

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

        // require(balance0 <= type(uint112).max, "OVERFLOW");
        // require(balance1 <= type(uint112).max, "OVERFLOW");
        if(balance0 > type(uint112).max){
            revert Pair__Overflow();
        }
        if(balance1 > type(uint112).max){
            revert Pair__Overflow();
        }
        
        uint32 blockTimestamp = uint32(block.timestamp);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;

        if(timeElapsed > 0 && reserve0 != 0 && reserve1 != 0){
            uint price0 = uint(reserve1) * 1e18 /reserve0;
            uint price1 = uint(reserve0) * 1e18/reserve1;

            price0CumulativeLast += price0 * timeElapsed;
            price1CumulativeLast += price1 * timeElapsed;
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        
        emit Sync(reserve0, reserve1);
    }

    function _safeTransfer(address token, address to, uint amount) internal{
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));

        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert Pair__TransferFailed();
        }
    }

    //protocol fee logic->
    function _mintProtocolFee(uint112 _reserve0, uint112 _reserve1) internal{
        uint _totalSupply = totalSupply();
        address feeTo = IFactory(factory).feeTo();
        if(feeTo == address(0)){
            if(kLast != 0){
                kLast = 0;
            }
            return;
        }else{
            if(kLast != 0 ){
                uint rootK = Math.sqrt(uint256(_reserve0) * uint256(_reserve1));
                uint rootKLast = Math.sqrt(kLast);
                if(rootK > rootKLast){
                    uint liquidity = _totalSupply * (rootK - rootKLast)/(rootK * 5 + rootKLast);
                    if(liquidity > 0 ){
                        _mint(feeTo, liquidity);
                    }
                }
            }
        }
    }

    function mint(address to) external lock returns(uint _liquidity){
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // require(balance0 <= type(uint112).max, "OVERFLOW");
        // require(balance1 <= type(uint112).max, "OVERFLOW");

        if(balance0 > type(uint112).max){
            revert Pair__Overflow();
        }
        if(balance1 > type(uint112).max){
            revert Pair__Overflow();
        }

        uint112 oldReserve0 = reserve0;
        uint112 oldReserve1 = reserve1;

        _mintProtocolFee(oldReserve0, oldReserve1);

        //amounts sent by msg.sender->
        uint256 amount0 = balance0 - oldReserve0;
        uint256 amount1 = balance1 - oldReserve1;

        // require(amount0 > 0 && amount1 > 0, "Amount must be more than zero");
        if(amount0 == 0 || amount1 ==0 ){
            revert Pair__AmountMustBeMoreThanZero();
        }

        uint256 liquidity;
        uint256 _totalSupply = totalSupply();

        if(_totalSupply == 0){
            uint256 sqrtK = Math.sqrt(amount0 * amount1);
            if(sqrtK <= MINIMUM_LIQUIDITY){
                revert Pair__InsufficientLiquidityMinted();
            }
            liquidity = sqrtK - MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY);
            _mint(to, liquidity);

        }else{ //liquidity already exists in pool
            // require(oldReserve0 > 0 && oldReserve1 > 0, "zero reserves!");
            if(oldReserve0 == 0 || oldReserve1 == 0){
                revert Pair__ZeroReserves();
            }


            uint liquidity0 = (amount0 * _totalSupply)/oldReserve0;
            uint liquidity1 = (amount1 * _totalSupply)/oldReserve1;

            liquidity = Math.min(liquidity0, liquidity1);
            if(liquidity <= 0){
                revert Pair__InsufficientLiquidityMinted();
            }else{
                _mint(to, liquidity);
            }
        }
        emit Mint(msg.sender, amount0, amount1);
        _update();

        address feeTo = IFactory(factory).feeTo();
        if(feeTo != address(0)){
            kLast = uint256(reserve0) * uint256(reserve1);
        }

        return liquidity;
    }

    function burn(address to) external lock returns(uint _amount0, uint _amount1){
        uint liquidity = balanceOf(address(this)); //since contract itself is lptoken
        if(liquidity == 0){
            revert Pair__AmountZero();
        }
        address _token0 = token0;
        address _token1 = token1;

        uint112 oldReserve0 = reserve0;
        uint112 oldReserve1 = reserve1;

        _mintProtocolFee(oldReserve0, oldReserve1);

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

            emit Burn(msg.sender, amount0, amount1, to);
            _update();
            bool feeOn = IFactory(factory).feeTo() != address(0);
            if (feeOn) {
                kLast = uint256(reserve0) * uint256(reserve1);
            }

            return(amount0, amount1);
        }
    }

    function swap(uint amount0Out, uint amount1Out, address to) external lock {
        uint112 _reserve0 = reserve0;
        uint112 _reserve1 = reserve1;
        address _token0 = token0;
        address _token1 = token1;

        if(amount0Out == 0 && amount1Out == 0){
            revert Pair__InsufficientOutputAmount();
        }
        if(amount0Out > 0 && amount1Out > 0){
            revert Pair__Forbidden();
        }
        if(to == _token0 || to == _token1){
            revert Pair__InvalidAddress();
        }

        if(amount0Out > _reserve0 || amount1Out > _reserve1){
            revert Pair__Forbidden();
        }
        if(amount0Out > 0){
            _safeTransfer(_token0, to, amount0Out);
        }
        if(amount1Out>0){
            _safeTransfer(_token1, to, amount1Out);
        }

        //reading new balances->
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));

        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

        if(amount0In==0 && amount1In ==0){
            revert Pair__AmountZero();
        }
        
        uint balance0Adjusted = balance0 * 1000 - amount0In*3;
        uint balance1Adjusted = balance1 * 1000 - amount1In*3;

        
        if(balance0Adjusted * balance1Adjusted < uint256(_reserve0) * uint256(_reserve1) * 1000*1000){
            revert Pair__InvariantViolation();
        }

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
        _update();
    }

    function skim(address to) external lock {
        address _token0 = token0;
        address _token1 = token1;

        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)) - reserve0);
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)) - reserve1);
    }

    function sync() external lock {
        _update();
    }

}