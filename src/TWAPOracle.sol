// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TWAPOracle
/// @notice Manipulation-resistant TWAP using cumulative price snapshots.
///         Fixes: permissioned updates, minimum observation window,
///                staleness guard, bidirectional price support.

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

    /// @notice Minimum time between snapshots — prevents single-block manipulation
    uint256 public constant MIN_UPDATE_INTERVAL = 5 minutes;

    /// @notice TWAP window used for price calculation
    uint256 public constant TWAP_WINDOW = 30 minutes;

    /// @notice Price is considered stale after this duration
    uint256 public constant MAX_STALENESS = 2 hours;

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

    /// Authorized updaters (keeper bots, router, etc.)
    mapping(address => bool) public isUpdater;

    address public owner;

    // =========================================================
    // ERRORS
    // =========================================================

    error NotAuthorized();
    error TooSoon();
    error NoObservation();
    error StalePrice();
    error InsufficientTimeElapsed();
    error ZeroAddress();

    // =========================================================
    // EVENTS
    // =========================================================

    event OracleUpdated(address indexed pair, uint256 timestamp);
    event UpdaterSet(address indexed updater, bool authorized);

    // =========================================================
    // MODIFIERS
    // =========================================================

    modifier onlyUpdater() {
        if (!isUpdater[msg.sender] && msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor() {
        owner = msg.sender;
        isUpdater[msg.sender] = true;
    }

    // =========================================================
    // UPDATE
    // =========================================================

    /// @notice Snapshots the current cumulative prices for a pair.
    ///         Must be called by authorized keeper at regular intervals.
    function update(address pair) external onlyUpdater {
        Observation storage obs = observations[pair];

        // Rate-limit updates to prevent micro-snapshot manipulation
        if (
            obs.timestamp != 0 &&
            block.timestamp < obs.timestamp + MIN_UPDATE_INTERVAL
        ) {
            revert TooSoon();
        }

        // (,, uint32 pairTimestamp) = IPairTWAP(pair).getReserves();

        observations[pair] = Observation({
            price0Cumulative: IPairTWAP(pair).price0CumulativeLast(),
            price1Cumulative: IPairTWAP(pair).price1CumulativeLast(),
            timestamp: block.timestamp
        });

        emit OracleUpdated(pair, block.timestamp);
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

        // Staleness guard
        if (block.timestamp > obs.timestamp + MAX_STALENESS) revert StalePrice();

        uint256 timeElapsed = block.timestamp - obs.timestamp;
        if (timeElapsed < MIN_UPDATE_INTERVAL) revert InsufficientTimeElapsed();

        uint256 currentCumulative = IPairTWAP(pair).price0CumulativeLast();

        // TWAP = Δcumulative / Δtime
        // price0CumulativeLast is already scaled by 1e18 in Pair._update()
        price = (currentCumulative - obs.price0Cumulative) / timeElapsed;
    }

    function _getTWAP1(address pair) internal view returns (uint256 price) {
        Observation memory obs = observations[pair];

        if (obs.timestamp == 0) revert NoObservation();
        if (block.timestamp > obs.timestamp + MAX_STALENESS) revert StalePrice();

        uint256 timeElapsed = block.timestamp - obs.timestamp;
        if (timeElapsed < MIN_UPDATE_INTERVAL) revert InsufficientTimeElapsed();

        uint256 currentCumulative = IPairTWAP(pair).price1CumulativeLast();
        price = (currentCumulative - obs.price1Cumulative) / timeElapsed;
    }

    // =========================================================
    // ADMIN
    // =========================================================

    function setUpdater(address updater, bool authorized) external onlyOwner {
        if (updater == address(0)) revert ZeroAddress();
        isUpdater[updater] = authorized;
        emit UpdaterSet(updater, authorized);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}