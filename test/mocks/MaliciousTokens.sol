// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Token whose transfer() always returns false
contract ReturnFalseToken is ERC20 {
    constructor() ERC20("ReturnFalse", "RFT") {}

    function mint(address to, uint amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint) public pure override returns (bool) {
        return false; // always lies
    }

    function transferFrom(address, address, uint) public pure override returns (bool) {
        return false;
    }
}

/// @notice Token whose transfer() reverts with no data (like USDT on mainnet)
contract NoReturnToken is ERC20 {
    constructor() ERC20("NoReturn", "NRT") {}

    function mint(address to, uint amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint) public pure override returns (bool) {
        revert(); // no error message, no return value
    }

    function transferFrom(address, address, uint) public pure override returns (bool) {
        revert();
    }
}

/// @notice Reentrant token — calls back into pair.swap() during transferFrom
interface IPairMinimal {
    function swap(uint, uint, address) external;
}

contract ReentrantToken is ERC20 {
    address public pair;
    bool public attacking;

    constructor() ERC20("Reentrant", "RNT") {}

    function mint(address to, uint amount) external {
        _mint(to, amount);
    }

    function setPair(address _pair) external {
        pair = _pair;
    }

    function transferFrom(address from, address to, uint amount) public override returns (bool) {
        // do the real transfer first
        super.transferFrom(from, to, amount);

        // then try to reenter swap during the transfer
        if (!attacking && pair != address(0)) {
            attacking = true;
            try IPairMinimal(pair).swap(0, 1, address(this)) {} catch {}
            attacking = false;
        }
        return true;
    }
}