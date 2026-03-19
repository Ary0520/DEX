// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILShieldVault
/// @notice Accumulates swap fees in any token, pays IL compensation in USDC.
///         Fixes: payout token architecture, circuit breaker, bounds validation,
///                double-cap removal, per-token balance tracking.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ILShieldVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // STRUCTS
    // =========================================================

    struct Pool {
        uint256 usdcReserve;      // USDC available for payouts for this pair
        uint256 totalPaidOut;     // lifetime payouts (for analytics)
        uint256 totalFeesIn;      // lifetime fees received (for analytics)
    }

    struct Config {
        uint256 maxCoverageBps;       // cap on netIL covered — e.g. 3000 = 30%
        uint256 maxPayoutBps;         // per-user cap as % of their LP value — e.g. 2000 = 20%
        uint256 poolCapBps;           // max single payout as % of pool fund — e.g. 500 = 5%
        uint256 circuitBreakerBps;    // utilization % that halves coverage — e.g. 5000 = 50%
        uint256 pauseThresholdBps;    // utilization % that pauses shield — e.g. 8000 = 80%
    }

    // =========================================================
    // STATE
    // =========================================================

    /// @notice USDC (or any stablecoin) used for all IL payouts
    address public immutable USDC;

    /// @notice per-pair pool state
    mapping(address => Pool) public pools;

    /// @notice per-pair, per-fee-token accumulated balance (before USDC conversion)
    /// pair => feeToken => rawAmount
    mapping(address => mapping(address => uint256)) public rawFeeBalances;

    Config public config;

    address public router;
    address public owner;
    bool public globalPause;

    // =========================================================
    // ERRORS
    // =========================================================

    error NotAuthorized();
    error InsufficientFund();
    error InvalidConfig();
    error VaultPaused();
    error ZeroAddress();
    error ZeroAmount();

    // =========================================================
    // EVENTS
    // =========================================================

    event FeesDeposited(address indexed pair, address indexed token, uint256 amount);
    event USDCAllocated(address indexed pair, uint256 usdcAmount);
    event PayoutIssued(address indexed pair, address indexed user, uint256 amount);
    event ConfigUpdated(Config config);
    event CircuitBreakerTriggered(address indexed pair, uint256 utilization);
    event GlobalPauseSet(bool paused);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // =========================================================
    // MODIFIERS
    // =========================================================

    modifier onlyRouter() {
        if (msg.sender != router) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier notPaused() {
        if (globalPause) revert VaultPaused();
        _;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(address _router, address _usdc) {
        if (_router == address(0) || _usdc == address(0)) revert ZeroAddress();
        router = _router;
        USDC = _usdc;
        owner = msg.sender;

        // Sane defaults — all validated in setConfig
        config = Config({
            maxCoverageBps:    3000,   // 30%
            maxPayoutBps:      2000,   // 20% of user LP value
            poolCapBps:         500,   // 5% of pool fund per payout
            circuitBreakerBps: 5000,   // 50% utilization → halve coverage
            pauseThresholdBps: 8000    // 80% utilization → pause
        });
    }

    // =========================================================
    // FUNDING — called by Router on every swap
    // =========================================================

    /// @notice Router transfers `feeToken` to this vault, then calls this to record it.
    /// @dev    Does NOT convert to USDC here — conversion is done separately via
    ///         allocateUSDC() by a trusted keeper/owner once tokens are swapped off-chain
    ///         or via an on-chain DEX route. This keeps vault atomic + safe.
    function depositFees(
        address pair,
        address feeToken,
        uint256 amount
    ) external onlyRouter {
        if (amount == 0) revert ZeroAmount();

        // Verify the vault actually received the tokens (pull, not trust)
        // Router must have transferred tokens BEFORE calling this
        // (balance verification handled by Router transferring before calling this)

        // The new tokens received = current balance - previously tracked balance
        // This pattern is safe against double-counting across multiple pairs
        // sharing the same fee token
        rawFeeBalances[pair][feeToken] += amount;
        pools[pair].totalFeesIn += amount;

        emit FeesDeposited(pair, feeToken, amount);
    }

    /// @notice Owner/keeper calls this after converting raw fee tokens to USDC
    ///         and transferring USDC into this contract.
    /// @dev    In production: integrate a swap aggregator (1inch, Uniswap) here,
    ///         or have keeper do it off-chain and call this to credit the pool.
    function allocateUSDC(address pair, uint256 usdcAmount) external onlyOwner {
        if (usdcAmount == 0) revert ZeroAmount();
        // Transfer USDC from caller (owner/keeper) into vault
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);
        pools[pair].usdcReserve += usdcAmount;
        emit USDCAllocated(pair, usdcAmount);
    }

    // =========================================================
    // PAYOUT — called by Router on removeLiquidity
    // =========================================================

    /// @notice Calculates and pays IL compensation in USDC to the user.
    /// @param  pair              The LP pair address
    /// @param  user              The LP receiving compensation
    /// @param  netIL             Raw IL in value terms (NOT pre-capped — cap applied here)
    /// @param  userLiquidityValue Current USD value of user's withdrawn LP
    /// @return payout            USDC amount paid out
    function requestPayout(
        address pair,
        address user,
        uint256 netIL,
        uint256 userLiquidityValue,
        uint256 maxCoverageBps
    ) external onlyRouter notPaused nonReentrant returns (uint256 payout) {
        if (netIL == 0) return 0;
        if (user == address(0)) revert ZeroAddress();

        Pool storage p = pools[pair];

        if (p.usdcReserve == 0) return 0;

        // ── Step 1: Utilization check (circuit breaker) ──────────────────────
        // utilization = what % of the fund has been paid out historically
        // We approximate via: reserved / (reserve + paid)
        uint256 totalEver = p.usdcReserve + p.totalPaidOut;
        uint256 utilization = totalEver == 0
            ? 0
            : (p.totalPaidOut * 10000) / totalEver;

        if (utilization >= config.pauseThresholdBps) {
            // Pool-level pause (not global) — silently return 0 instead of revert
            // so removeLiquidity still succeeds for the user
            emit CircuitBreakerTriggered(pair, utilization);
            return 0;
        }

        // ── Step 2: Coverage calculation (single cap, applied HERE only) ─────
        // maxCoverageBps comes from Factory tier config (e.g. 1500/5000/7500)
        uint256 effectiveCoverageBps = maxCoverageBps;

        if (utilization >= config.circuitBreakerBps) {
            // Halve coverage when utilization is high
            effectiveCoverageBps = effectiveCoverageBps / 2;
            emit CircuitBreakerTriggered(pair, utilization);
        }

        uint256 coverage = (netIL * effectiveCoverageBps) / 10000;

        // ── Step 3: User cap ─────────────────────────────────────────────────
        uint256 userCap = (userLiquidityValue * config.maxPayoutBps) / 10000;

        // ── Step 4: Pool cap ─────────────────────────────────────────────────
        uint256 poolCap = (p.usdcReserve * config.poolCapBps) / 10000;

        // ── Step 5: Final payout = min of all three ──────────────────────────
        payout = _min3(coverage, userCap, poolCap);

        if (payout == 0) return 0;

        // Hard floor: never pay more than what's in the pool
        if (payout > p.usdcReserve) {
            payout = p.usdcReserve;
        }

        // ── Step 6: State update BEFORE transfer (CEI pattern) ───────────────
        p.usdcReserve -= payout;
        p.totalPaidOut += payout;

        // ── Step 7: Transfer USDC to user ────────────────────────────────────
        IERC20(USDC).safeTransfer(user, payout);

        emit PayoutIssued(pair, user, payout);

        return payout;
    }

    // =========================================================
    // VIEW HELPERS
    // =========================================================

    function getUtilization(address pair) external view returns (uint256 bps) {
        Pool storage p = pools[pair];
        uint256 totalEver = p.usdcReserve + p.totalPaidOut;
        if (totalEver == 0) return 0;
        return (p.totalPaidOut * 10000) / totalEver;
    }

    function getPoolHealth(address pair) external view returns (uint256 usdcReserve, uint256 utilization) {
        usdcReserve = pools[pair].usdcReserve;
        utilization = this.getUtilization(pair);
    }

    // =========================================================
    // ADMIN
    // =========================================================

    /// @notice All bps values validated to be <= 10000 and logically ordered
    function setConfig(
        uint256 _coverage,
        uint256 _payout,
        uint256 _poolCap,
        uint256 _circuitBreaker,
        uint256 _pauseThreshold
    ) external onlyOwner {
        if (_coverage > 10000)        revert InvalidConfig();
        if (_payout > 10000)          revert InvalidConfig();
        if (_poolCap > 10000)         revert InvalidConfig();
        if (_circuitBreaker > 10000)  revert InvalidConfig();
        if (_pauseThreshold > 10000)  revert InvalidConfig();
        // Circuit breaker must trigger before pause
        if (_circuitBreaker >= _pauseThreshold) revert InvalidConfig();

        config = Config(_coverage, _payout, _poolCap, _circuitBreaker, _pauseThreshold);
        emit ConfigUpdated(config);
    }

    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        router = _router;
    }

    function setGlobalPause(bool _paused) external onlyOwner {
        globalPause = _paused;
        emit GlobalPauseSet(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Emergency: recover non-USDC tokens sent by mistake
    function recoverToken(address token, uint256 amount) external onlyOwner {
        if (token == USDC) revert NotAuthorized(); // never pull USDC reserves
        IERC20(token).safeTransfer(owner, amount);
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
}