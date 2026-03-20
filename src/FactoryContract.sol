// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Factory
/// @author AryyyInLoop
/// @notice Deploys Pair contracts via CREATE2. Single source of truth for
///         pool tier config (fee + IL coverage). Auto-detects tier from
///         token whitelist; admin can override anytime.

import {Pair} from "./Pair.sol";

contract Factory {

    // =========================================================
    // TIER SYSTEM
    // =========================================================

    /// @notice Three tiers — determines swap fee + IL coverage intensity
    enum Tier { Volatile, BlueChip, Stable }

    struct TierConfig {
        uint256 vaultFeeBps;       // fee % going to IL vault  (of amountIn)
        uint256 treasuryFeeBps;    // fee % going to treasury  (of amountIn)
        uint256 lpFeeBps;          // fee % staying in Pair    (of amountIn)
        uint256 maxCoverageBps;    // IL coverage cap for this tier
    }

    // =========================================================
    // STATE
    // =========================================================

    address public feeTo;
    address public feeToSetter;

    /// pair address => its tier
    mapping(address => Tier) public pairTier;

    /// tier => its fee + coverage config
    mapping(Tier => TierConfig) public tierConfig;

    /// tokens in this set are treated as "stable" for auto-detection
    mapping(address => bool) public isStableToken;

    /// tokens in this set are treated as "blue chip" for auto-detection
    mapping(address => bool) public isBlueChipToken;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    // =========================================================
    // ERRORS
    // =========================================================

    error DEX__IdenticalTokens();
    error DEX__ZeroAddress();
    error DEX__PairAlreadyExists();
    error DEX__Forbidden();
    error DEX__PairNotFound();
    error DEX__InvalidConfig();

    // =========================================================
    // EVENTS
    // =========================================================

    event PairCreated(address indexed token0, address indexed token1, address pair, Tier tier);
    event TierOverridden(address indexed pair, Tier oldTier, Tier newTier);
    event TierConfigUpdated(Tier indexed tier, TierConfig config);
    event TokenWhitelistUpdated(address indexed token, bool isStable, bool isBlueChip);

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor() {
        feeToSetter = msg.sender;

        // ── Default tier configs ──────────────────────────────
        //
        // STABLE:    total ~0.10% (0.03 vault + 0.02 treasury + 0.05 LP)
        //            IL coverage: 15% (IL is nearly zero on stable pairs)
        //
        // BLUECHIP:  total ~0.35% (0.10 vault + 0.05 treasury + 0.20 LP)  (not exact, see note)
        //            IL coverage: 50%
        //
        // VOLATILE:  total ~0.55% (0.15 vault + 0.10 treasury + 0.30 LP)
        //            IL coverage: 75%
        //
        // NOTE: lpFeeBps here is stored for reference + Router reads it.
        //       The actual LP fee enforcement is in Pair.sol's invariant check.
        //       Pair currently hardcodes 0.3% (3/1000). For stable/bluechip
        //       pairs the Router will send a different lpFeeBps to Pair —
        //       Pair.sol will need a per-pool fee param in a future upgrade.
        //       For now, LP fee in Pair stays 0.3% for all tiers; only the
        //       vault + treasury split changes dynamically via Router.

        tierConfig[Tier.Stable] = TierConfig({
            vaultFeeBps:    3,      // 0.03%
            treasuryFeeBps: 2,      // 0.02%
            lpFeeBps:       5,      // 0.05% (aspirational — Pair currently takes 0.30%)
            maxCoverageBps: 1500    // 15% IL coverage
        });

        tierConfig[Tier.BlueChip] = TierConfig({
            vaultFeeBps:    10,     // 0.10%
            treasuryFeeBps: 5,      // 0.05%
            lpFeeBps:       20,     // 0.20% (aspirational)
            maxCoverageBps: 5000    // 50% IL coverage
        });

        tierConfig[Tier.Volatile] = TierConfig({
            vaultFeeBps:    15,     // 0.15%
            treasuryFeeBps: 10,     // 0.10%
            lpFeeBps:       30,     // 0.30%
            maxCoverageBps: 7500    // 75% IL coverage
        });
    }

    // =========================================================
    // CREATE PAIR
    // =========================================================

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB)                               revert DEX__IdenticalTokens();
        if (tokenA == address(0) || tokenB == address(0))  revert DEX__ZeroAddress();

        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        if (getPair[token0][token1] != address(0)) revert DEX__PairAlreadyExists();

        // ── CREATE2 deploy ────────────────────────────────────
        bytes memory bytecode = type(Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        address _pair;
        assembly {
            _pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        if (_pair == address(0)) revert DEX__PairAlreadyExists();

        Pair(_pair).initialize(token0, token1);

        pair = _pair;
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        _registeredPairs[pair] = true;

        // ── Auto-detect tier ──────────────────────────────────
        Tier detectedTier = _detectTier(token0, token1);
        pairTier[pair] = detectedTier;

        emit PairCreated(token0, token1, pair, detectedTier);
    }

    // =========================================================
    // TIER READS — called by Router on every swap + removeLiquidity
    // =========================================================


    /// @notice Convenience: just the tier enum for a pair
    function getPairTier(address pair) external view returns (Tier) {
        return pairTier[pair];
    }

    /// @notice Returns tier config as individual values (for Router interface compatibility)
    function getPairConfig(address pair) external view returns (
        uint256 vaultFeeBps,
        uint256 treasuryFeeBps,
        uint256 lpFeeBps,
        uint256 maxCoverageBps
    ) {
        TierConfig memory cfg = tierConfig[pairTier[pair]];
        return (cfg.vaultFeeBps, cfg.treasuryFeeBps, cfg.lpFeeBps, cfg.maxCoverageBps);
    }

    // =========================================================
    // AUTO-DETECTION LOGIC
    // =========================================================

    /// @dev Both tokens stable   → Stable tier
    ///      Either token bluechip (and neither is a mismatch) → BlueChip
    ///      Anything else         → Volatile (safest default)
    function _detectTier(address token0, address token1) internal view returns (Tier) {
        bool t0Stable    = isStableToken[token0];
        bool t1Stable    = isStableToken[token1];
        bool t0BlueChip  = isBlueChipToken[token0];
        bool t1BlueChip  = isBlueChipToken[token1];

        if (t0Stable && t1Stable) {
            return Tier.Stable;
        }

        // One stable + one bluechip → BlueChip tier (e.g. ETH/USDC)
        if ((t0Stable && t1BlueChip) || (t0BlueChip && t1Stable)) {
            return Tier.BlueChip;
        }

        // Both bluechip (e.g. ETH/BTC)
        if (t0BlueChip && t1BlueChip) {
            return Tier.BlueChip;
        }

        return Tier.Volatile;
    }

    /// @notice Public version — preview what tier a pair WOULD get before creation
    function detectTier(address tokenA, address tokenB) external view returns (Tier) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _detectTier(t0, t1);
    }

    // =========================================================
    // ADMIN — TIER OVERRIDE
    // =========================================================

    /// @notice Override the auto-detected tier for any existing pair.
    ///         Owner can set it to any tier anytime (upgrade or downgrade).
    function setPairTier(address pair, Tier tier) external {
        if (msg.sender != feeToSetter) revert DEX__Forbidden();
        if (pair == address(0))        revert DEX__ZeroAddress();
        // Verify this is actually one of our pairs
        if (!_isPairRegistered(pair))  revert DEX__PairNotFound();

        Tier oldTier = pairTier[pair];
        pairTier[pair] = tier;

        emit TierOverridden(pair, oldTier, tier);
    }

    /// @notice Update the fee + coverage config for an entire tier.
    ///         Affects ALL pairs in that tier immediately.
    function setTierConfig(
        Tier tier,
        uint256 vaultFeeBps,
        uint256 treasuryFeeBps,
        uint256 lpFeeBps,
        uint256 maxCoverageBps
    ) external {
        if (msg.sender != feeToSetter) revert DEX__Forbidden();

        // Bounds: individual fees must be sane, total must not exceed 2%
        if (vaultFeeBps    > 200) revert DEX__InvalidConfig();
        if (treasuryFeeBps > 200) revert DEX__InvalidConfig();
        if (lpFeeBps       > 200) revert DEX__InvalidConfig();
        if (maxCoverageBps > 10000) revert DEX__InvalidConfig();
        if (vaultFeeBps + treasuryFeeBps + lpFeeBps > 200) revert DEX__InvalidConfig();

        TierConfig memory cfg = TierConfig(vaultFeeBps, treasuryFeeBps, lpFeeBps, maxCoverageBps);
        tierConfig[tier] = cfg;

        emit TierConfigUpdated(tier, cfg);
    }

    // =========================================================
    // ADMIN — TOKEN WHITELIST
    // =========================================================

    /// @notice Register tokens for auto-detection.
    ///         e.g. setTokenTier(USDC, true, false)  → stable
    ///              setTokenTier(WETH, false, true)  → bluechip
    ///              setTokenTier(SHIB, false, false) → volatile (default)
    function setTokenTier(address token, bool stable, bool blueChip) external {
        if (msg.sender != feeToSetter) revert DEX__Forbidden();
        if (token == address(0))       revert DEX__ZeroAddress();
        // A token can't be both stable AND bluechip
        if (stable && blueChip)        revert DEX__InvalidConfig();

        isStableToken[token]   = stable;
        isBlueChipToken[token] = blueChip;

        emit TokenWhitelistUpdated(token, stable, blueChip);
    }

    // =========================================================
    // EXISTING ADMIN
    // =========================================================

    function setFeeTo(address newFeeTo) external {
        if (msg.sender != feeToSetter) revert DEX__Forbidden();
        feeTo = newFeeTo;
    }

    function setFeeToSetter(address newSetter) external {
        if (msg.sender != feeToSetter) revert DEX__Forbidden();
        if (newSetter == address(0))   revert DEX__ZeroAddress();
        feeToSetter = newSetter;
    }

    // =========================================================
    // COMPUTE ADDRESS (CREATE2 — off-chain helper)
    // =========================================================

    function computePairAddress(address tokenA, address tokenB) external view returns (address) {
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(type(Pair).creationCode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    // =========================================================
    // VIEW HELPERS
    // =========================================================

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    function _isPairRegistered(address pair) internal view returns (bool) {
        // A registered pair always has a non-zero entry in allPairs
        // We check via the getPair mapping using the pair's own tokens
        // Cheaper: just check if pair is in the mapping by using Pair interface
        // Safest without importing Pair: check allPairs array is impractical at scale
        // Best approach: maintain a reverse mapping
        return _registeredPairs[pair];
    }

    /// @dev reverse lookup: pair address → is registered
    mapping(address => bool) private _registeredPairs;
}