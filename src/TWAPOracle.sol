// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TWAPOracle
/// @notice Manipulation-resistant TWAP using cumulative price snapshots.
///         
/// LAZY TWAP DESIGN:
///         - PERMISSIONLESS: Anyone can call update() to snapshot prices
///         - RATE-LIMITED: Updates only allowed every 2 hours (prevents spam)
///         - SELF-MAINTAINING: FeeConverter callers auto-update when needed
///         - NO KEEPER REQUIRED: System maintains itself through user activity
///         
/// HOW IT WORKS:
///         1. Someone calls update() to take initial snapshot
///         2. TWAP window grows automatically: 30 min → 2 hours → 8 hours
///         3. Longer window = more manipulation-resistant
///         4. When window reaches 2 hours, anyone can update again
///         5. FeeConverter callers are incentivized to update (0.1% bonus)
///         
/// SECURITY:
///         - Minimum 30-minute window enforced (prevents short-term manipulation)
///         - Maximum 8-hour staleness (rejects very old prices)
///         - Cumulative prices from Pair contract (can't be manipulated in single block)

interface IPairTWAP {
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

contract TWAPOracle {

    // =========================================================
    // CONSTANTS
    // =========================================================

    /// @notice Minimum TWAP window before price can be used — prevents manipulation
    ///         TWAP must be at least 30 minutes old to be considered safe
    uint256 public constant MIN_TWAP_WINDOW = 30 minutes;

    /// @notice Maximum time between updates before oracle auto-updates
    ///         After 2 hours, callers should update the oracle
    uint256 public constant MAX_UPDATE_WINDOW = 2 hours;

    /// @notice Price is considered stale after this duration
    ///         Increased from 2 hours to 8 hours for lazy TWAP resilience
    uint256 public constant MAX_STALENESS = 8 hours;

    // =========================================================
    // STRUCTS
    // =========================================================

    struct Observation {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint256 timestamp;
    }

    // =========================================================
    // STATE
    // =========================================================

    /// pair => snapshot
    mapping(address => Observation) public observations;

    address public owner;

    // =========================================================
    // ERRORS
    // =========================================================

    error NotAuthorized();
    error UpdateTooSoon();
    error NoObservation();
    error StalePrice();
    error TWAPWindowTooSmall();
    error ZeroAddress();

    // =========================================================
    // EVENTS
    // =========================================================

    event OracleUpdated(address indexed pair, uint256 timestamp, address indexed updater);

    // =========================================================
    // MODIFIERS
    // =========================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor() {
        owner = msg.sender;
    }

    // =========================================================
    // UPDATE
    // =========================================================

    /// @notice Snapshots the current cumulative prices for a pair.
    ///         PERMISSIONLESS — anyone can call this to update the oracle.
    ///         Rate-limited to prevent spam: can only update if window >= MAX_UPDATE_WINDOW (2 hours).
    ///         
    /// @dev    Lazy TWAP design: updates are only needed every 2 hours.
    ///         Between updates, the TWAP window grows automatically (30 min → 2 hours).
    ///         Longer windows = more manipulation-resistant.
    ///         
    ///         FeeConverter callers are incentivized to call this when needed
    ///         (they get 0.1% bonus, costs ~$0.50 gas to update).
    function update(address pair) external {
        Observation storage obs = observations[pair];

        // Rate-limit: only allow update if window is >= 2 hours OR first update
        // This prevents spam while allowing the system to self-maintain
        if (obs.timestamp != 0) {
            uint256 windowSize = block.timestamp - obs.timestamp;
            if (windowSize < MAX_UPDATE_WINDOW) {
                revert UpdateTooSoon();
            }
        }

        observations[pair] = Observation({
            price0Cumulative: IPairTWAP(pair).price0CumulativeLast(),
            price1Cumulative: IPairTWAP(pair).price1CumulativeLast(),
            timestamp: block.timestamp
        });

        emit OracleUpdated(pair, block.timestamp, msg.sender);
    }

    // =========================================================
    // READ
    // =========================================================

    /// @notice Returns TWAP price of token0 in terms of token1 (18 decimal fixed point)
    function getTWAP(address pair) external view returns (uint256 price) {
        return _getTWAP0(pair);
    }

    /// @notice Price of token0 in token1 units  (how much token1 per 1 token0)
    function getTWAP0(address pair) external view returns (uint256) {
        return _getTWAP0(pair);
    }

    /// @notice Price of token1 in token0 units  (how much token0 per 1 token1)
    function getTWAP1(address pair) external view returns (uint256) {
        return _getTWAP1(pair);
    }

    /// @notice Returns TWAP in the direction of: how much tokenB per 1 tokenA
    function getTWAPForTokens(
        address pair,
        address tokenA
    ) external view returns (uint256) {
        address token0 = IPairTWAP(pair).token0();
        if (tokenA == token0) {
            return _getTWAP0(pair);
        } else {
            return _getTWAP1(pair);
        }
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    function _getTWAP0(address pair) internal view returns (uint256 price) {
        Observation memory obs = observations[pair];

        if (obs.timestamp == 0) revert NoObservation();

        uint256 timeElapsed = block.timestamp - obs.timestamp;

        // Minimum window check: TWAP must be at least 30 minutes old
        // This prevents manipulation via short-term price swings
        if (timeElapsed < MIN_TWAP_WINDOW) revert TWAPWindowTooSmall();

        // Staleness guard: reject if observation is too old (>8 hours)
        if (timeElapsed > MAX_STALENESS) revert StalePrice();

        uint256 currentCumulative = IPairTWAP(pair).price0CumulativeLast();

        // TWAP = Δcumulative / Δtime
        // price0CumulativeLast is already scaled by 1e18 in Pair._update()
        price = (currentCumulative - obs.price0Cumulative) / timeElapsed;
    }

    function _getTWAP1(address pair) internal view returns (uint256 price) {
        Observation memory obs = observations[pair];

        if (obs.timestamp == 0) revert NoObservation();

        uint256 timeElapsed = block.timestamp - obs.timestamp;

        // Minimum window check
        if (timeElapsed < MIN_TWAP_WINDOW) revert TWAPWindowTooSmall();

        // Staleness guard
        if (timeElapsed > MAX_STALENESS) revert StalePrice();

        uint256 currentCumulative = IPairTWAP(pair).price1CumulativeLast();
        price = (currentCumulative - obs.price1Cumulative) / timeElapsed;
    }

    // =========================================================
    // ADMIN
    // =========================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}