// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILShieldVault v2
/// @notice Production IL insurance vault with:
///         - CoverageCurve for dynamic coverage (not flat %)
///         - IL Vault Stakers (passive insurance sellers)
///         - Per-pool exposure tracking (for vault health calc)
///         - Stake slashing when vault is drained
///         - Unstake cooldown to prevent bank run attacks
///
/// STAKER MODEL (learned from Nexus Mutual):
///   Stakers deposit USDC into a pool's vault.
///   They earn a share of swap fees proportional to their stake.
///   When IL payouts happen, stakers' capital is used first.
///   Stakers cannot instantly withdraw — 14-day cooldown.
///   This prevents the Bancor failure mode: nobody can "run" during a crisis.

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
        uint256 usdcReserve;         // total USDC available (fees + staker deposits)
        uint256 stakerDeposits;      // portion of reserve from stakers
        uint256 feeDeposits;         // portion of reserve from swap fees
        uint256 totalPaidOut;        // lifetime payouts
        uint256 totalFeesIn;         // lifetime fees received
        uint256 totalExposureUSDC;   // sum of all open position netIL estimates
                                     // used for vault health calculation
    }

    struct StakerPosition {
        uint256 amount;           // USDC staked
        uint256 shares;           // proportional share of pool (scaled by 1e18)
        uint256 rewardDebt;       // for fee reward accounting (MasterChef pattern)
        uint256 unstakeRequestTime; // when they requested unstake (0 = not requested)
    }

    struct Config {
        uint256 maxPayoutBps;         // per-user cap as % of LP value. e.g. 2000 = 20%
        uint256 poolCapBps;           // max single payout as % of pool fund. e.g. 500 = 5%
        uint256 circuitBreakerBps;    // utilization that halves coverage. e.g. 5000
        uint256 pauseThresholdBps;    // utilization that pauses shield. e.g. 8000
        uint256 stakerFeeShareBps;    // % of vault fees going to stakers. e.g. 5000 = 50%
        uint256 unstakeCooldown;      // seconds stakers must wait to withdraw
    }

    // =========================================================
    // STATE
    // =========================================================

    address public immutable USDC;

    mapping(address => Pool) public pools;

    /// pair => feeToken => rawAmount (pre-USDC-conversion tracking)
    mapping(address => mapping(address => uint256)) public rawFeeBalances;

    /// pair => staker => position
    mapping(address => mapping(address => StakerPosition)) public stakerPositions;

    /// pair => total shares outstanding (for pro-rata fee distribution)
    mapping(address => uint256) public totalShares;

    /// pair => accumulated fee per share (MasterChef pattern, scaled 1e18)
    mapping(address => uint256) public accFeePerShare;

    Config public config;
    address public router;
    address public owner;
    bool public globalPause;
    address public feeConverter;

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
    error NotConverter();
    error InsufficientFund();

    // =========================================================
    // EVENTS
    // =========================================================

    event FeesDeposited(address indexed pair, address indexed token, uint256 amount);
    event USDCAllocated(address indexed pair, uint256 usdcAmount);
    event PayoutIssued(address indexed pair, address indexed user, uint256 amount, uint256 coverageBps);
    event CircuitBreakerTriggered(address indexed pair, uint256 utilization);
    event Staked(address indexed pair, address indexed staker, uint256 amount, uint256 shares);
    event UnstakeRequested(address indexed pair, address indexed staker, uint256 requestTime);
    event Unstaked(address indexed pair, address indexed staker, uint256 amount);
    event FeeHarvested(address indexed pair, address indexed staker, uint256 amount);
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

    modifier onlyConverter() {
        if (msg.sender != feeConverter) revert NotConverter();
        _;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(address _router, address _usdc) {
        if (_router == address(0) || _usdc == address(0)) revert ZeroAddress();
        router  = _router;
        USDC    = _usdc;
        owner   = msg.sender;

        config = Config({
            maxPayoutBps:      2000,   // 20% of LP value per claim
            poolCapBps:         500,   // 5% of pool fund per single payout
            circuitBreakerBps: 5000,   // 50% utilization → halve coverage
            pauseThresholdBps: 8000,   // 80% utilization → pause pool
            stakerFeeShareBps: 5000,   // 50% of vault fees → stakers
            unstakeCooldown:   14 days // Bancor lesson: no instant exits
        });
    }

    // =========================================================
    // FUNDING — called by Router per swap
    // =========================================================

    function depositFees(
        address pair,
        address feeToken,
        uint256 amount
    ) external onlyRouter {
        if (amount == 0) revert ZeroAmount();

        rawFeeBalances[pair][feeToken] += amount;
        pools[pair].totalFeesIn += amount;

        emit FeesDeposited(pair, feeToken, amount);
    }

    /// @notice Keeper converts raw fee tokens → USDC and credits pool.
    ///         Also distributes staker fee share via MasterChef accFeePerShare.
    function allocateUSDC(address pair, uint256 usdcAmount) external {

        if (msg.sender != owner && msg.sender != feeConverter) revert NotAuthorized();

        if (usdcAmount == 0) revert ZeroAmount();

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

        Pool storage p = pools[pair];

        // Split: stakerFeeShareBps goes to stakers as yield
        //        remainder goes to payout reserve
        uint256 toStakers = (usdcAmount * config.stakerFeeShareBps) / 10000;
        uint256 toReserve = usdcAmount - toStakers;

        p.feeDeposits  += toReserve;
        p.usdcReserve  += toReserve;

        // Distribute staker share via accFeePerShare (MasterChef pattern)
        // This is O(1) regardless of number of stakers — gas safe
        if (toStakers > 0 && totalShares[pair] > 0) {
            accFeePerShare[pair] += (toStakers * 1e18) / totalShares[pair];
            // The USDC for staker fees stays in the contract,
            // stakers claim it lazily via harvestFees()
        } else if (toStakers > 0) {
            // No stakers yet — redirect to reserve
            p.feeDeposits += toStakers;
            p.usdcReserve += toStakers;
        }

        emit USDCAllocated(pair, usdcAmount);
    }

    // =========================================================
    // EXPOSURE TRACKING — called by Router on addLiquidity / removeLiquidity
    // =========================================================

    /// @notice Router updates estimated outstanding IL exposure for a pool.
    ///         Used by CoverageCurve to compute vault health.
    ///         Exposure = sum of (depositValue - currentValue) for all open positions.
    ///         Router should call this on every addLiquidity and removeLiquidity.
    function updateExposure(address pair, uint256 newTotalExposureUSDC) external onlyRouter {
        pools[pair].totalExposureUSDC = newTotalExposureUSDC;
        emit ExposureUpdated(pair, newTotalExposureUSDC);
    }

    // =========================================================
    // PAYOUT — called by Router on removeLiquidity
    // =========================================================

    /// @notice Computes dynamic coverage via CoverageCurve, enforces all caps,
    ///         pays USDC directly to user.
    ///
    /// @param  pair                 LP pair address
    /// @param  user                 LP receiving compensation
    /// @param  netIL                Raw IL in USDC value (NOT pre-capped)
    /// @param  userLiquidityValue   Current USDC value of withdrawn LP
    /// @param  tierCeilingBps       Pool tier's max coverage (from Factory)
    /// @param  secondsInPool        How long LP was deposited (from PositionManager)
    function requestPayout(
        address pair,
        address user,
        uint256 netIL,
        uint256 userLiquidityValue,
        uint256 tierCeilingBps,
        uint256 secondsInPool
    ) external onlyRouter notPaused nonReentrant returns (uint256 payout) {
        if (netIL == 0)             return 0;
        if (user == address(0))     revert ZeroAddress();

        Pool storage p = pools[pair];
        if (p.usdcReserve == 0)     return 0;

        // ── Step 1: Pool-level circuit breaker ────────────────────────────
        uint256 totalEver   = p.usdcReserve + p.totalPaidOut;
        uint256 utilization = totalEver == 0
            ? 0
            : (p.totalPaidOut * 10000) / totalEver;

        if (utilization >= config.pauseThresholdBps) {
            emit CircuitBreakerTriggered(pair, utilization);
            return 0;  // silent return — user's removeLiquidity still succeeds
        }

        // ── Step 2: Compute coverage via CoverageCurve ────────────────────
        // CoverageCurve applies: time saturation × vault health × tier ceiling
        uint256 effectiveCoverageBps = CoverageCurve.compute(
            tierCeilingBps,
            secondsInPool,
            p.usdcReserve,
            p.totalExposureUSDC
        );

        // Circuit breaker: high utilization → halve coverage
        if (utilization >= config.circuitBreakerBps) {
            effectiveCoverageBps = effectiveCoverageBps / 2;
            emit CircuitBreakerTriggered(pair, utilization);
        }

        if (effectiveCoverageBps == 0) return 0;

        // ── Step 3: Apply coverage to netIL ──────────────────────────────
        uint256 coverage = (netIL * effectiveCoverageBps) / 10000;

        // ── Step 4: User cap ──────────────────────────────────────────────
        uint256 userCap = (userLiquidityValue * config.maxPayoutBps) / 10000;

        // ── Step 5: Pool cap ──────────────────────────────────────────────
        uint256 poolCap = (p.usdcReserve * config.poolCapBps) / 10000;

        // ── Step 6: Final payout = min of all three ───────────────────────
        payout = _min3(coverage, userCap, poolCap);
        if (payout == 0) return 0;

        // Absolute hard floor
        if (payout > p.usdcReserve) payout = p.usdcReserve;

        // ── Step 7: CEI — state before transfer ───────────────────────────
        p.usdcReserve  -= payout;
        p.totalPaidOut += payout;

        // Reduce staker deposits proportionally if payout exceeds fee reserve
        // Stakers absorb losses beyond the fee buffer
        if (payout > p.feeDeposits) {
            uint256 stakerLoss = payout - p.feeDeposits;
            p.feeDeposits = 0;
            p.stakerDeposits = p.stakerDeposits > stakerLoss
                ? p.stakerDeposits - stakerLoss
                : 0;
        } else {
            p.feeDeposits -= payout;
        }

        // ── Step 8: Transfer USDC to user ─────────────────────────────────
        IERC20(USDC).safeTransfer(user, payout);

        emit PayoutIssued(pair, user, payout, effectiveCoverageBps);

        return payout;
    }

    // =========================================================
    // IL VAULT STAKERS
    // =========================================================

    /// @notice Deposit USDC into a pool's vault as an insurance seller.
    ///         Stakers earn swap fees. Their capital backs IL payouts.
    ///         No instant withdrawal — unstakeCooldown enforced.
    function stake(address pair, uint256 amount) external nonReentrant notPaused {
        if (amount == 0) revert ZeroAmount();
        if (pair == address(0)) revert ZeroAddress();

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);

        Pool storage p = pools[pair];
        StakerPosition storage pos = stakerPositions[pair][msg.sender];

        // Settle any pending fee rewards before changing shares
        _settleRewards(pair, msg.sender);

        // Compute shares to mint
        // First staker: shares = amount (1:1)
        // Subsequent: shares = amount * totalShares / stakerDeposits
        uint256 sharesToMint;
        if (totalShares[pair] == 0 || p.stakerDeposits == 0) {
            sharesToMint = amount;
        } else {
            sharesToMint = (amount * totalShares[pair]) / p.stakerDeposits;
        }

        pos.amount   += amount;
        pos.shares   += sharesToMint;

        // Update rewardDebt to current accFeePerShare so they don't
        // retroactively claim fees from before they staked
        pos.rewardDebt = (pos.shares * accFeePerShare[pair]) / 1e18;

        totalShares[pair]    += sharesToMint;
        p.stakerDeposits     += amount;
        p.usdcReserve        += amount;

        // Reset any pending unstake request
        pos.unstakeRequestTime = 0;

        emit Staked(pair, msg.sender, amount, sharesToMint);
    }

    /// @notice Start the unstake cooldown timer.
    ///         Stakers must call this, wait unstakeCooldown seconds, then call unstake().
    ///         Prevents bank-run attacks during market stress (Bancor lesson).
    function requestUnstake(address pair) external {
        StakerPosition storage pos = stakerPositions[pair][msg.sender];
        if (pos.shares == 0) revert InsufficientShares();

        pos.unstakeRequestTime = block.timestamp;
        emit UnstakeRequested(pair, msg.sender, block.timestamp);
    }

    /// @notice Withdraw staked USDC after cooldown period.
    ///         Proportional to shares. Accounts for any losses from payouts.
    function unstake(address pair, uint256 sharesToBurn) external nonReentrant {
        StakerPosition storage pos = stakerPositions[pair][msg.sender];

        if (pos.unstakeRequestTime == 0)  revert UnstakeNotRequested();
        if (block.timestamp < pos.unstakeRequestTime + config.unstakeCooldown)
            revert CooldownNotMet();
        if (sharesToBurn == 0 || sharesToBurn > pos.shares)
            revert InsufficientShares();

        // Settle fee rewards first
        _settleRewards(pair, msg.sender);

        Pool storage p = pools[pair];

        // USDC to return = proportional share of remaining stakerDeposits
        // This naturally handles losses: if payout drained staker capital,
        // stakerDeposits < original, so each share is worth less.
        uint256 usdcToReturn = (sharesToBurn * p.stakerDeposits) / totalShares[pair];

        // State update before transfer (CEI)
        pos.shares   -= sharesToBurn;
        pos.amount    = pos.shares == 0
            ? 0
            : (pos.amount * pos.shares) / (pos.shares + sharesToBurn);
        pos.rewardDebt = (pos.shares * accFeePerShare[pair]) / 1e18;

        // Reset unstake request if fully exited
        if (pos.shares == 0) pos.unstakeRequestTime = 0;

        totalShares[pair]    -= sharesToBurn;
        p.stakerDeposits      = p.stakerDeposits > usdcToReturn
            ? p.stakerDeposits - usdcToReturn
            : 0;
        p.usdcReserve         = p.usdcReserve > usdcToReturn
            ? p.usdcReserve - usdcToReturn
            : 0;

        IERC20(USDC).safeTransfer(msg.sender, usdcToReturn);

        emit Unstaked(pair, msg.sender, usdcToReturn);
    }

    /// @notice Claim accumulated fee rewards without unstaking.
    function harvestFees(address pair) external nonReentrant {
        _settleRewards(pair, msg.sender);
    }

    /// @notice Preview pending fee rewards for a staker.
    function pendingFees(address pair, address staker) external view returns (uint256) {
        StakerPosition memory pos = stakerPositions[pair][staker];
        if (pos.shares == 0) return 0;

        uint256 pending = (pos.shares * accFeePerShare[pair]) / 1e18;
        return pending > pos.rewardDebt ? pending - pos.rewardDebt : 0;
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
        uint256 feeDeposits,
        uint256 utilization,
        uint256 totalExposure
    ) {
        Pool storage p = pools[pair];
        uint256 totalEver = p.usdcReserve + p.totalPaidOut;
        uint256 util = totalEver == 0 ? 0 : (p.totalPaidOut * 10000) / totalEver;

        return (
            p.usdcReserve,
            p.stakerDeposits,
            p.feeDeposits,
            util,
            p.totalExposureUSDC
        );
    }

    /// @notice Returns current total exposure for a pool.
    ///         Used by Router to calculate updated exposure on add/remove.
    function getExposure(address pair) external view returns (uint256) {
        return pools[pair].totalExposureUSDC;
    }

    // =========================================================
    // ADMIN
    // =========================================================

    function setConfig(
        uint256 _maxPayout,
        uint256 _poolCap,
        uint256 _circuitBreaker,
        uint256 _pauseThreshold,
        uint256 _stakerFeeShare,
        uint256 _unstakeCooldown
    ) external onlyOwner {
        if (_maxPayout        > 10000)          revert InvalidConfig();
        if (_poolCap          > 10000)          revert InvalidConfig();
        if (_circuitBreaker   > 10000)          revert InvalidConfig();
        if (_pauseThreshold   > 10000)          revert InvalidConfig();
        if (_stakerFeeShare   > 10000)          revert InvalidConfig();
        if (_circuitBreaker   >= _pauseThreshold) revert InvalidConfig();
        if (_unstakeCooldown  < 7 days)         revert InvalidConfig(); // min 7d cooldown always

        config = Config(
            _maxPayout, _poolCap, _circuitBreaker,
            _pauseThreshold, _stakerFeeShare, _unstakeCooldown
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

    function recoverToken(address token, uint256 amount) external onlyOwner {
        if (token == USDC) revert NotAuthorized();
        IERC20(token).safeTransfer(owner, amount);
    }

    /// @notice Owner sets the FeeConverter address once after deployment.
    function setFeeConverter(address _converter) external onlyOwner {
        if (_converter == address(0)) revert ZeroAddress();
        feeConverter = _converter;
    }

/// @notice FeeConverter calls this to pull raw fee tokens for conversion.
///         Only callable by the registered FeeConverter.
///         Reduces rawFeeBalances before transfer — CEI pattern.
    function withdrawRawFees(
        address pair,
        address feeToken,
        uint256 amount
    ) external onlyConverter nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (rawFeeBalances[pair][feeToken] < amount) revert InsufficientFund();

        // CEI — reduce balance before transfer
        rawFeeBalances[pair][feeToken] -= amount;

        IERC20(feeToken).safeTransfer(feeConverter, amount);
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    /// @dev MasterChef-style reward settlement.
    ///      Calculates fees earned since last checkpoint and transfers them.
    function _settleRewards(address pair, address staker) internal {
        StakerPosition storage pos = stakerPositions[pair][staker];
        if (pos.shares == 0) return;

        uint256 accumulated = (pos.shares * accFeePerShare[pair]) / 1e18;
        uint256 pending = accumulated > pos.rewardDebt
            ? accumulated - pos.rewardDebt
            : 0;

        pos.rewardDebt = accumulated;

        if (pending > 0) {
            IERC20(USDC).safeTransfer(staker, pending);
            emit FeeHarvested(pair, staker, pending);
        }
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
}