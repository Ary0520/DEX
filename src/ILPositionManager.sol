// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILPositionManager
/// @notice Tracks LP positions for IL Shield.
///         Fixes: partial withdrawal support, weighted-average timestamp,
///                proportional position reduction on burn.

contract ILPositionManager {

    // =========================================================
    // STRUCTS
    // =========================================================

    struct Position {
        uint256 liquidity;         // total LP tokens tracked
        uint256 valueAtDeposit;    // weighted avg deposit value (TWAP-normalized)
        uint256 timestamp;         // weighted avg deposit timestamp
    }

    // =========================================================
    // STATE
    // =========================================================

    /// pair => user => position
    mapping(address => mapping(address => Position)) public positions;

    address public router;

    // =========================================================
    // ERRORS
    // =========================================================

    error NotRouter();
    error ZeroLiquidity();
    error InsufficientLiquidity();
    error ZeroAddress();

    // =========================================================
    // EVENTS
    // =========================================================

    event PositionRecorded(address indexed pair, address indexed user, uint256 liquidity, uint256 depositValue);
    event PositionReduced(address indexed pair, address indexed user, uint256 liquidityRemoved, uint256 liquidityRemaining);
    event PositionCleared(address indexed pair, address indexed user);

    // =========================================================
    // MODIFIERS
    // =========================================================

    modifier onlyRouter() {
        if (msg.sender != router) revert NotRouter();
        _;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(address _router) {
        if (_router == address(0)) revert ZeroAddress();
        router = _router;
    }

    // =========================================================
    // WRITE — called by Router
    // =========================================================

    /// @notice Records or updates an LP deposit position.
    ///         On re-deposit: weighted avg of value AND timestamp.
    function recordDeposit(
        address pair,
        address user,
        uint256 liquidity,
        uint256 depositValue
    ) external onlyRouter {
        if (liquidity == 0) revert ZeroLiquidity();

        Position storage p = positions[pair][user];

        if (p.liquidity == 0) {
            // Fresh position
            p.valueAtDeposit = depositValue;
            p.timestamp      = block.timestamp;
            p.liquidity      = liquidity;
        } else {
            // Re-deposit: weighted average for BOTH value and timestamp
            uint256 totalLiquidity = p.liquidity + liquidity;

            // Weighted avg deposit value
            p.valueAtDeposit =
                (p.valueAtDeposit * p.liquidity + depositValue * liquidity)
                / totalLiquidity;

            // Weighted avg timestamp
            // This means a tiny re-deposit barely moves the timestamp
            // while a large re-deposit proportionally delays the lock
            p.timestamp =
                (p.timestamp * p.liquidity + block.timestamp * liquidity)
                / totalLiquidity;

            p.liquidity = totalLiquidity;
        }

        emit PositionRecorded(pair, user, liquidity, depositValue);
    }

    /// @notice Reduces a position proportionally on partial withdrawal.
    ///         valueAtDeposit and timestamp are preserved (don't change on withdrawal —
    ///         they represent the original entry conditions for IL calculation).
    /// @param  liquidityRemoved  LP tokens being withdrawn now
    /// @return proportionalValue The deposit value attributable to the withdrawn portion
    /// @return positionTimestamp The weighted avg timestamp (for lock check in Router)
    function reducePosition(
        address pair,
        address user,
        uint256 liquidityRemoved
    ) external onlyRouter returns (uint256 proportionalValue, uint256 positionTimestamp) {
        Position storage p = positions[pair][user];

        if (p.liquidity == 0) revert ZeroLiquidity();
        if (liquidityRemoved > p.liquidity) revert InsufficientLiquidity();

        // Proportional deposit value for the removed slice
        // e.g. removing 25% of liquidity → 25% of valueAtDeposit
        proportionalValue = (p.valueAtDeposit * liquidityRemoved) / p.liquidity;
        positionTimestamp = p.timestamp;

        if (liquidityRemoved == p.liquidity) {
            // Full withdrawal — clean up
            delete positions[pair][user];
            emit PositionCleared(pair, user);
        } else {
            // Partial withdrawal — reduce liquidity and value proportionally
            // valueAtDeposit per unit stays the same, total scales down
            p.valueAtDeposit =
                (p.valueAtDeposit * (p.liquidity - liquidityRemoved))
                / p.liquidity;
            p.liquidity -= liquidityRemoved;
            // timestamp intentionally NOT changed on withdrawal

            emit PositionReduced(pair, user, liquidityRemoved, p.liquidity);
        }

        return (proportionalValue, positionTimestamp);
    }

    /// @notice Full position clear — only used in edge cases (e.g. migration)
    function clearPosition(address pair, address user) external onlyRouter {
        delete positions[pair][user];
        emit PositionCleared(pair, user);
    }

    // =========================================================
    // VIEW
    // =========================================================

    function getPosition(address pair, address user)
        external
        view
        returns (Position memory)
    {
        return positions[pair][user];
    }
}