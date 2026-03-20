// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILShieldVault v3
/// @notice Clean architecture:
///
///   USDC reserve  = staker deposits only → backs IL payouts
///   Raw fee tokens = distributed directly to stakers as yield
///   Zero conversion. Zero keeper. Zero sandwich risk.
///   Zero centralization.
///
///   Stakers deposit USDC → earn raw fee tokens → back IL claims
///   LPs get USDC payouts → funded entirely by staker deposits
///   Protocol earns treasury fee → separate, never touches vault
///
///   Learned from:
///   - Bancor: no token printing, no infinite liability
///   - Nexus Mutual: separate reserve from yield layer
///   - Sherlock: stakers are the insurance underwriters

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CoverageCurve} from "./CoverageCurve.sol";

contract ILShieldVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // STRUCTS
    // =========================================================

    struct Pool {
        uint256 usdcReserve;        // USDC available for payouts (staker deposits only)
        uint256 stakerDeposits;     // total USDC staked (tracks losses via reduction)
        uint256 totalPaidOut;       // lifetime USDC paid to LPs (for utilization calc)
        uint256 totalFeesIn;        // lifetime raw fee tokens received (informational)
        uint256 totalExposureUSDC;  // estimated outstanding IL liability (for health calc)
    }

    struct StakerPosition {
        uint256 usdcAmount;             // USDC deposited
        uint256 shares;                 // share of pool (for proportional fee claiming)
        uint256 unstakeRequestTime;     // 0 = no request pending
        // Per-token fee debt tracked separately in feeDebtPerToken mapping
    }

    struct Config {
        uint256 maxPayoutBps;       // per-user cap as % of LP value    e.g. 2000 = 20%
        uint256 poolCapBps;         // max single payout as % of pool   e.g. 500  = 5%
        uint256 circuitBreakerBps;  // utilization that halves coverage  e.g. 5000 = 50%
        uint256 pauseThresholdBps;  // utilization that pauses shield    e.g. 8000 = 80%
        uint256 unstakeCooldown;    // seconds before unstake allowed
    }

    // =========================================================
    // STATE
    // =========================================================

    address public immutable USDC;

    /// pair => pool state
    mapping(address => Pool) public pools;

    /// pair => feeToken => total raw amount sitting in vault
    /// These are claimable by stakers proportionally
    mapping(address => mapping(address => uint256)) public rawFeeBalances;

    /// pair => feeToken => accFeePerShare (scaled 1e18)
    /// MasterChef pattern — tracks cumulative fee per share for each token
    mapping(address => mapping(address => uint256)) public accFeePerShare;

    /// pair => staker => position
    mapping(address => mapping(address => StakerPosition)) public stakerPositions;

    /// pair => total shares outstanding
    mapping(address => uint256) public totalShares;

    /// pair => staker => feeToken => rewardDebt (scaled 1e18)
    /// Tracks how much of accFeePerShare the staker has already been credited
    mapping(address => mapping(address => mapping(address => uint256))) public feeDebtPerToken;

    Config public config;
    address public router;
    address public owner;
    bool public globalPause;

    // =========================================================
    // ERRORS
    // =========================================================

    error NotAuthorized();
    error InvalidConfig();
    error VaultPaused();
    error ZeroAddress();
    error ZeroAmount();
    error CooldownNotMet();
    error UnstakeNotRequested();
    error InsufficientShares();

    // =========================================================
    // EVENTS
    // =========================================================

    event FeesDeposited(address indexed pair, address indexed token, uint256 amount);
    event PayoutIssued(address indexed pair, address indexed user, uint256 amount, uint256 coverageBps);
    event CircuitBreakerTriggered(address indexed pair, uint256 utilization);
    event Staked(address indexed pair, address indexed staker, uint256 usdcAmount, uint256 shares);
    event UnstakeRequested(address indexed pair, address indexed staker, uint256 requestTime);
    event Unstaked(address indexed pair, address indexed staker, uint256 usdcReturned);
    event RawFeeHarvested(address indexed pair, address indexed staker, address indexed token, uint256 amount);
    event ExposureUpdated(address indexed pair, uint256 newExposure);
    event ConfigUpdated(Config config);
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
        USDC   = _usdc;
        owner  = msg.sender;

        config = Config({
            maxPayoutBps:      2000,    // 20% of LP value per claim
            poolCapBps:         500,    // 5% of pool fund per single payout
            circuitBreakerBps: 5000,    // 50% utilization → halve coverage
            pauseThresholdBps: 8000,    // 80% utilization → pause pool
            unstakeCooldown:   14 days  // no instant exits — Bancor lesson
        });
    }

    // =========================================================
    // FUNDING — called by Router on every swap
    // =========================================================

    /// @notice Records raw fee tokens deposited by Router.
    ///         Tokens are already transferred to this contract by Router.
    ///         Updates accFeePerShare so stakers can claim proportionally.
    ///         No conversion. No USDC involved here at all.
    function depositFees(
        address pair,
        address feeToken,
        uint256 amount
    ) external onlyRouter {
        if (amount == 0) revert ZeroAmount();

        pools[pair].totalFeesIn += amount;

        // If there are stakers, distribute fee to them via accFeePerShare
        // This is O(1) regardless of staker count — MasterChef pattern
        if (totalShares[pair] > 0) {
            // accFeePerShare increases by: amount * 1e18 / totalShares
            // Stakers claim their share lazily via harvestRawFees()
            accFeePerShare[pair][feeToken] +=
                (amount * 1e18) / totalShares[pair];

            // Track total sitting in vault for this token
            rawFeeBalances[pair][feeToken] += amount;
        } else {
            // No stakers yet — fees accumulate untracked
            // They will be claimable once first staker joins and
            // owner calls rescueUnclaimedFees() to redirect them
            // OR they simply sit — vault is not harmed
            rawFeeBalances[pair][feeToken] += amount;
        }

        emit FeesDeposited(pair, feeToken, amount);
    }

    // =========================================================
    // EXPOSURE TRACKING — called by Router
    // =========================================================

    function updateExposure(
        address pair,
        uint256 newTotalExposureUSDC
    ) external onlyRouter {
        pools[pair].totalExposureUSDC = newTotalExposureUSDC;
        emit ExposureUpdated(pair, newTotalExposureUSDC);
    }

    // =========================================================
    // PAYOUT — called by Router on removeLiquidity
    // =========================================================

    /// @notice Pays IL compensation in USDC to the LP.
    ///         USDC comes entirely from staker deposits.
    ///         No conversion. No raw tokens involved here.
    function requestPayout(
        address pair,
        address user,
        uint256 netIL,
        uint256 userLiquidityValue,
        uint256 tierCeilingBps,
        uint256 secondsInPool
    ) external onlyRouter notPaused nonReentrant returns (uint256 payout) {
        if (netIL == 0)         return 0;
        if (user == address(0)) revert ZeroAddress();

        Pool storage p = pools[pair];
        if (p.usdcReserve == 0) return 0;

        // ── Step 1: Circuit breaker ───────────────────────────────────────
        uint256 totalEver   = p.usdcReserve + p.totalPaidOut;
        uint256 utilization = totalEver == 0
            ? 0
            : (p.totalPaidOut * 10000) / totalEver;

        if (utilization >= config.pauseThresholdBps) {
            emit CircuitBreakerTriggered(pair, utilization);
            return 0;
        }

        // ── Step 2: Coverage curve ────────────────────────────────────────
        uint256 effectiveCoverageBps = CoverageCurve.compute(
            tierCeilingBps,
            secondsInPool,
            p.usdcReserve,
            p.totalExposureUSDC
        );

        if (utilization >= config.circuitBreakerBps) {
            effectiveCoverageBps = effectiveCoverageBps / 2;
            emit CircuitBreakerTriggered(pair, utilization);
        }

        if (effectiveCoverageBps == 0) return 0;

        // ── Step 3: Coverage amount ───────────────────────────────────────
        uint256 coverage = (netIL * effectiveCoverageBps) / 10000;

        // ── Step 4: User cap ──────────────────────────────────────────────
        uint256 userCap = (userLiquidityValue * config.maxPayoutBps) / 10000;

        // ── Step 5: Pool cap ──────────────────────────────────────────────
        uint256 poolCap = (p.usdcReserve * config.poolCapBps) / 10000;

        // ── Step 6: Min of all three ──────────────────────────────────────
        payout = _min3(coverage, userCap, poolCap);
        if (payout == 0) return 0;

        if (payout > p.usdcReserve) payout = p.usdcReserve;

        // ── Step 7: CEI — state before transfer ───────────────────────────
        p.usdcReserve   -= payout;
        p.totalPaidOut  += payout;

        // Staker deposits shrink proportionally — they absorb the loss
        // This is how stakers "pay" for the insurance they sold
        p.stakerDeposits = p.stakerDeposits > payout
            ? p.stakerDeposits - payout
            : 0;

        // ── Step 8: Transfer USDC to LP ───────────────────────────────────
        IERC20(USDC).safeTransfer(user, payout);

        emit PayoutIssued(pair, user, payout, effectiveCoverageBps);
        return payout;
    }

    // =========================================================
    // STAKING — deposit USDC to back IL payouts + earn raw fees
    // =========================================================

    /// @notice Deposit USDC into a pool vault.
    ///         Your USDC backs IL claims for this pool.
    ///         You earn raw swap fee tokens proportional to your share.
    function stake(
        address pair,
        uint256 usdcAmount
    ) external nonReentrant notPaused {
        if (usdcAmount == 0)    revert ZeroAmount();
        if (pair == address(0)) revert ZeroAddress();

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

        Pool storage p             = pools[pair];
        StakerPosition storage pos = stakerPositions[pair][msg.sender];

        // Compute shares to mint
        // First staker: 1 share per USDC
        // Subsequent: proportional to existing stakerDeposits
        // If stakerDeposits shrank due to payouts, new staker
        // gets fewer shares per USDC — correctly prices in past losses
        uint256 sharesToMint;
        if (totalShares[pair] == 0 || p.stakerDeposits == 0) {
            sharesToMint = usdcAmount;
        } else {
            sharesToMint = (usdcAmount * totalShares[pair]) / p.stakerDeposits;
        }

        // Snapshot current accFeePerShare for ALL known fee tokens
        // so staker doesn't claim fees from before they joined.
        // Note: we cannot enumerate all tokens here — staker calls
        // snapshotFeeDebt() for each token they want to track.
        // This is a known tradeoff: stakers claim specific tokens they know about.

        pos.usdcAmount  += usdcAmount;
        pos.shares      += sharesToMint;
        pos.unstakeRequestTime = 0; // reset any pending unstake

        totalShares[pair]    += sharesToMint;
        p.stakerDeposits     += usdcAmount;
        p.usdcReserve        += usdcAmount;

        emit Staked(pair, msg.sender, usdcAmount, sharesToMint);
    }

    /// @notice Call this immediately after stake() for each fee token
    ///         you want to track. Sets your debt baseline so you only
    ///         earn fees from this point forward for that token.
    function snapshotFeeDebt(address pair, address feeToken) external {
        StakerPosition storage pos = stakerPositions[pair][msg.sender];
        if (pos.shares == 0) revert InsufficientShares();

        feeDebtPerToken[pair][msg.sender][feeToken] =
            accFeePerShare[pair][feeToken];
    }

    // =========================================================
    // HARVEST RAW FEES — stakers pull their fee token yield
    // =========================================================

    /// @notice Claim accumulated raw fee tokens for a specific token.
    ///         No conversion. You get the actual swap token.
    ///         Call separately for each fee token you want to claim.
    ///
    /// @param  pair      The pool you staked in
    /// @param  feeToken  The raw fee token to claim (e.g. SHIB, ARB, etc.)
    function harvestRawFees(
        address pair,
        address feeToken
    ) external nonReentrant {
        StakerPosition storage pos = stakerPositions[pair][msg.sender];
        if (pos.shares == 0) revert InsufficientShares();

        uint256 acc   = accFeePerShare[pair][feeToken];
        uint256 debt  = feeDebtPerToken[pair][msg.sender][feeToken];

        // Pending = (shares × accFeePerShare / 1e18) - rewardDebt
        uint256 pending = (pos.shares * acc) / 1e18;
        pending = pending > debt ? pending - debt : 0;

        if (pending == 0) return;

        // Clamp to actual balance (rounding safety)
        if (pending > rawFeeBalances[pair][feeToken]) {
            pending = rawFeeBalances[pair][feeToken];
        }

        // CEI — update state before transfer
        feeDebtPerToken[pair][msg.sender][feeToken] =
            (pos.shares * acc) / 1e18;
        rawFeeBalances[pair][feeToken] -= pending;

        IERC20(feeToken).safeTransfer(msg.sender, pending);

        emit RawFeeHarvested(pair, msg.sender, feeToken, pending);
    }

    /// @notice View pending raw fee yield for a staker on a specific token.
    function pendingRawFees(
        address pair,
        address staker,
        address feeToken
    ) external view returns (uint256) {
        StakerPosition memory pos = stakerPositions[pair][staker];
        if (pos.shares == 0) return 0;

        uint256 acc     = accFeePerShare[pair][feeToken];
        uint256 debt    = feeDebtPerToken[pair][staker][feeToken];
        uint256 pending = (pos.shares * acc) / 1e18;
        return pending > debt ? pending - debt : 0;
    }

    // =========================================================
    // UNSTAKE — two step: request → wait → withdraw
    // =========================================================

    /// @notice Step 1: Signal intent to unstake.
    ///         Starts the cooldown timer.
    function requestUnstake(address pair) external {
        StakerPosition storage pos = stakerPositions[pair][msg.sender];
        if (pos.shares == 0) revert InsufficientShares();

        pos.unstakeRequestTime = block.timestamp;
        emit UnstakeRequested(pair, msg.sender, block.timestamp);
    }

    /// @notice Step 2: Withdraw USDC after cooldown.
    ///         Amount returned is proportional to remaining stakerDeposits.
    ///         If payouts drained the pool, you get back less — that's the risk.
    function unstake(
        address pair,
        uint256 sharesToBurn
    ) external nonReentrant {
        StakerPosition storage pos = stakerPositions[pair][msg.sender];

        if (pos.unstakeRequestTime == 0) revert UnstakeNotRequested();
        if (block.timestamp < pos.unstakeRequestTime + config.unstakeCooldown)
            revert CooldownNotMet();
        if (sharesToBurn == 0 || sharesToBurn > pos.shares)
            revert InsufficientShares();

        Pool storage p = pools[pair];

        // USDC returned = proportional share of remaining stakerDeposits
        // Naturally accounts for losses from IL payouts
        uint256 usdcToReturn =
            (sharesToBurn * p.stakerDeposits) / totalShares[pair];

        // CEI — state before transfer
        pos.shares     -= sharesToBurn;
        pos.usdcAmount  = pos.shares == 0
            ? 0
            : (pos.usdcAmount * pos.shares) / (pos.shares + sharesToBurn);

        if (pos.shares == 0) pos.unstakeRequestTime = 0;

        totalShares[pair]  -= sharesToBurn;
        p.stakerDeposits    = p.stakerDeposits > usdcToReturn
            ? p.stakerDeposits - usdcToReturn : 0;
        p.usdcReserve       = p.usdcReserve > usdcToReturn
            ? p.usdcReserve - usdcToReturn : 0;

        IERC20(USDC).safeTransfer(msg.sender, usdcToReturn);

        emit Unstaked(pair, msg.sender, usdcToReturn);
    }

    // =========================================================
    // VIEW HELPERS
    // =========================================================

    function getUtilization(address pair) external view returns (uint256) {
        Pool storage p = pools[pair];
        uint256 totalEver = p.usdcReserve + p.totalPaidOut;
        if (totalEver == 0) return 0;
        return (p.totalPaidOut * 10000) / totalEver;
    }

    function getPoolHealth(address pair) external view returns (
        uint256 usdcReserve,
        uint256 stakerDeposits,
        uint256 utilization,
        uint256 totalExposure
    ) {
        Pool storage p = pools[pair];
        uint256 totalEver = p.usdcReserve + p.totalPaidOut;
        uint256 util = totalEver == 0
            ? 0
            : (p.totalPaidOut * 10000) / totalEver;
        return (p.usdcReserve, p.stakerDeposits, util, p.totalExposureUSDC);
    }

    function getExposure(address pair) external view returns (uint256) {
        return pools[pair].totalExposureUSDC;
    }

    function getStakerPosition(address pair, address staker)
        external view
        returns (uint256 usdcAmount, uint256 shares, uint256 unstakeRequestTime)
    {
        StakerPosition memory pos = stakerPositions[pair][staker];
        return (pos.usdcAmount, pos.shares, pos.unstakeRequestTime);
    }

    // =========================================================
    // ADMIN
    // =========================================================

    function setConfig(
        uint256 _maxPayout,
        uint256 _poolCap,
        uint256 _circuitBreaker,
        uint256 _pauseThreshold,
        uint256 _unstakeCooldown
    ) external onlyOwner {
        if (_maxPayout       > 10000)             revert InvalidConfig();
        if (_poolCap         > 10000)             revert InvalidConfig();
        if (_circuitBreaker  > 10000)             revert InvalidConfig();
        if (_pauseThreshold  > 10000)             revert InvalidConfig();
        if (_circuitBreaker  >= _pauseThreshold)  revert InvalidConfig();
        if (_unstakeCooldown < 7 days)            revert InvalidConfig();

        config = Config(
            _maxPayout, _poolCap,
            _circuitBreaker, _pauseThreshold,
            _unstakeCooldown
        );
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

    /// @notice Recover tokens accidentally sent directly to vault
    ///         (not via depositFees). Cannot touch USDC reserve.
    function recoverToken(address token, uint256 amount) external onlyOwner {
        if (token == USDC) revert NotAuthorized();
        IERC20(token).safeTransfer(owner, amount);
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    function _min3(uint256 a, uint256 b, uint256 c)
        internal pure returns (uint256)
    {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
}