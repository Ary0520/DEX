// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev transfer() always returns false — tests SafeERC20 rejection
contract ReturnFalseToken {
    string  public name     = "ReturnFalse";
    string  public symbol   = "RFT";
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return false;
    }
}

/// @dev transfer() emits no return value — like early USDT
contract NoReturnToken {
    string  public name     = "NoReturn";
    string  public symbol   = "NRT";
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
    }
    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
    }
}

/// @dev Attempts reentrancy on transfer — tests lock modifier
contract ReentrantToken {
    string  public name     = "Reentrant";
    string  public symbol   = "RET";
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes   public attackData;
    bool    public armed;

    function arm(address _target, bytes calldata _data) external {
        target     = _target;
        attackData = _data;
        armed      = true;
    }
    function disarm() external { armed = false; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        if (armed) {
            armed = false; // prevent infinite loop
            target.call(attackData);
        }
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        if (armed) {
            armed = false;
            target.call(attackData);
        }
        return true;
    }
}
