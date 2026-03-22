// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FeeConverter
/// @notice Permissionless contract that converts raw fee tokens sitting in
///         ILShieldVault into USDC, then credits the vault via allocateUSDC().
///
/// SECURITY DESIGN:
///
/// 1. TWAP-BASED MINIMUM OUTPUT
///    Every conversion enforces a minimum USDC output derived from the
///    30-minute TWAP price. Attacker cannot manipulate spot price to get
///    a bad conversion rate — TWAP moves slowly (minimum 5 min per update,
///    30 min window). Making the TWAP move enough to profit requires holding
///    a manipulated position for 30+ minutes, costing more than any gain.
///
/// 2. ADDITIONAL SLIPPAGE CAP (1%)
///    Even with a valid TWAP, max 1% deviation is allowed.
///    Conversion reverts if actual output < TWAP price * 99%.
///
/// 3. MINIMUM THRESHOLD
///    Conversions below $10 equivalent are rejected.
///    Prevents spam, dust attacks, and accFeePerShare precision loss.
///
/// 4. CALLER BONUS CAPPED AT 0.1% WITH HARD CAP
///    Caller earns 0.1% of converted USDC as incentive.
///    Hard cap: max 50 USDC per call regardless of conversion size.
///    Prevents whale gaming: convert $1M, earn $500 bonus.
///    At 0.1%, the protocol keeps 99.9% of all conversions.
///
/// 5. PER-TOKEN COOLDOWN
///    Each (pair, token) combination can only be converted once per hour.
///    Prevents rapid repeated conversions on the same token.
///
/// 6. ONLY REGISTERED PAIRS
///    Pair must exist in Factory. Prevents fake pair attacks.
///
/// 7. REENTRANCY PROTECTED
///    ReentrancyGuard on convert(). Router swap is called mid-function
///    but vault state is updated after — CEI enforced end-to-end.
///
/// 8. TWAP STALENESS CHECK
///    Conversion reverts if TWAP is stale (>2 hours old).
///    Oracle must be actively maintained for conversions to work.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IILShieldVaultExtended {
    function rawFeeBalances(address pair, address token) external view returns (uint256);
    function allocateUSDC(address pair, uint256 usdcAmount) external;
    function withdrawRawFees(address pair, address feeToken, uint256 amount) external;
}

interface IRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface ITWAPOracle {
    function getTWAPForTokens(address pair, address tokenA) external view returns (uint256);
}

interface IVaultAdmin {
    function router() external view returns (address);
}

contract FeeConverter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // CONSTANTS
    // =========================================================

    /// @dev Max slippage allowed vs TWAP price: 1%
    uint256 public constant MAX_SLIPPAGE_BPS    = 100;    // 1%

    /// @dev Caller bonus: 0.1% of USDC output
    uint256 public constant CALLER_BONUS_BPS    = 10;     // 0.1%

    /// @dev Hard cap on caller bonus per call: 50 USDC (6 decimals = 50e6)
    ///      Prevents whale gaming large conversions for outsized bonus
    uint256 public constant MAX_CALLER_BONUS    = 50e6;

   /// @dev Minimum raw token value to convert (in USDC terms, 6 decimals)
    ///      Prevents dust spam and precision loss in accFeePerShare
    uint256 public constant MIN_CONVERSION_USDC = 10e6;  // $10 minimum

    /// @dev Cooldown between conversions of the same (pair, token)
    uint256 public constant CONVERSION_COOLDOWN = 1 hours;

    uint256 public constant BPS_DENOMINATOR     = 10000;

    // =========================================================
    // STATE
    // =========================================================

    address public immutable factory;
    address public immutable vault;
    address public immutable twapOracle;
    address public immutable USDC;

    address public owner;

    /// pair => feeToken => last conversion timestamp
    /// Enforces per-token cooldown
    mapping(address => mapping(address => uint256)) public lastConversion;

    // =========================================================
    // ERRORS
    // =========================================================

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error PairNotRegistered();
    error CooldownNotMet();
    error BelowMinimum();
    error TWAPUnavailable();
    error SlippageExceeded();
    error TokenIsUSDC();
    error ConversionFailed();
    error NothingToConvert();

    // =========================================================
    // EVENTS
    // =========================================================

    event Converted(
        address indexed pair,
        address indexed feeToken,
        uint256 rawAmountIn,
        uint256 usdcOut,
        address indexed caller,
        uint256 callerBonus
    );
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(
        address _factory,
        address _vault,
        address _twapOracle,
        address _usdc
    ) {
        if (_factory    == address(0)) revert ZeroAddress();
        if (_vault      == address(0)) revert ZeroAddress();
        if (_twapOracle == address(0)) revert ZeroAddress();
        if (_usdc       == address(0)) revert ZeroAddress();

        factory    = _factory;
        vault      = _vault;
        twapOracle = _twapOracle;
        USDC       = _usdc;
        owner      = msg.sender;
    }

    // =========================================================
    // MAIN FUNCTION
    // =========================================================

    /// @notice Convert accumulated raw fee tokens for a pair into USDC.
    ///         Anyone can call this. Caller earns 0.1% of output (capped at 50 USDC).
    ///
    /// @param  pair        The LP pair whose vault fees to convert
    /// @param  feeToken    The raw fee token to convert (must not be USDC)
    ///
    /// Flow:
    ///   1. Validate pair is registered, token is not USDC, cooldown passed
    ///   2. Read raw balance from vault
    ///   3. Get TWAP price → compute minimum USDC output
    ///   4. Pull raw tokens from vault (vault approves this contract)
    ///   5. Swap via Router with minOut enforced
    ///   6. Send caller bonus
    ///   7. Send remaining USDC to vault via allocateUSDC()
    function convert(
        address pair,
        address feeToken
    ) external nonReentrant {
        // ── Validations ───────────────────────────────────────────────────

        if (feeToken == USDC) revert TokenIsUSDC();

        // Pair must be registered in Factory
        // We verify by checking token0/token1 exist — fake pairs won't be in Factory
        address verifyPair = IFactory(factory).getPair(
            _getPairToken0(pair),
            _getPairToken1(pair)
        );
        if (verifyPair != pair) revert PairNotRegistered();

        // Cooldown check
        if (block.timestamp < lastConversion[pair][feeToken] + CONVERSION_COOLDOWN)
            revert CooldownNotMet();

        // ── Get raw balance from vault ────────────────────────────────────
        uint256 rawAmount = IILShieldVaultExtended(vault).rawFeeBalances(pair, feeToken);
        if (rawAmount == 0) revert NothingToConvert();

        // ── TWAP price check ──────────────────────────────────────────────
        // Get USDC/feeToken pair address for TWAP lookup
        address usdcFeeTokenPair = IFactory(factory).getPair(feeToken, USDC);
        if (usdcFeeTokenPair == address(0)) revert TWAPUnavailable();

        uint256 twapPrice;
        try ITWAPOracle(twapOracle).getTWAPForTokens(
            usdcFeeTokenPair,
            feeToken
        ) returns (uint256 price) {
            if (price == 0) revert TWAPUnavailable();
            twapPrice = price;
        } catch {
            revert TWAPUnavailable();
        }

        // Expected USDC output at TWAP price
        // twapPrice is: how much USDC per 1 feeToken (18 decimal fixed point)
        uint256 expectedUsdc = (rawAmount * twapPrice) / 1e18;

        // Reject if expected output below minimum ($10)
        if (expectedUsdc < MIN_CONVERSION_USDC) revert BelowMinimum();

        // Minimum output with slippage: 99% of TWAP value
        uint256 minUsdcOut = (expectedUsdc * (BPS_DENOMINATOR - MAX_SLIPPAGE_BPS))
            / BPS_DENOMINATOR;

        // ── State update: record conversion timestamp ─────────────────────
        // Done BEFORE external calls (CEI pattern)
        lastConversion[pair][feeToken] = block.timestamp;

        
        IILShieldVaultExtended(vault).withdrawRawFees(pair, feeToken, rawAmount);

        // ── Approve Router to spend feeToken ─────────────────────────────
        address routerAddr = IVaultAdmin(vault).router();
        IERC20(feeToken).forceApprove(routerAddr, rawAmount);

        // ── Swap feeToken → USDC via Router ──────────────────────────────
        address[] memory path = new address[](2);
        path[0] = feeToken;
        path[1] = USDC;

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        try IRouter(routerAddr).swapExactTokensForTokens(
            rawAmount,
            minUsdcOut,
            path,
            address(this),
            block.timestamp
        ) returns (uint256[] memory) {
            // success
        } catch {
            // Swap failed — revert the timestamp update and return tokens
            lastConversion[pair][feeToken] = 0;
            IERC20(feeToken).forceApprove(routerAddr, 0);
            IERC20(feeToken).safeTransfer(vault, rawAmount);
            revert ConversionFailed();
        }

        uint256 usdcReceived = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

        // Final sanity check — ensure we actually got at least minUsdcOut
        if (usdcReceived < minUsdcOut) revert SlippageExceeded();

        // ── Caller bonus ──────────────────────────────────────────────────
        uint256 callerBonus = (usdcReceived * CALLER_BONUS_BPS) / BPS_DENOMINATOR;

        // Hard cap: never pay more than 50 USDC bonus per call
        if (callerBonus > MAX_CALLER_BONUS) {
            callerBonus = MAX_CALLER_BONUS;
        }

        uint256 usdcForVault = usdcReceived - callerBonus;

        // ── Send bonus to caller ──────────────────────────────────────────
        if (callerBonus > 0) {
            IERC20(USDC).safeTransfer(msg.sender, callerBonus);
        }

        // ── Credit vault via allocateUSDC ─────────────────────────────────
        // Approve vault to pull USDC from this contract
        IERC20(USDC).forceApprove(vault, usdcForVault);
        IILShieldVaultExtended(vault).allocateUSDC(pair, usdcForVault);

        emit Converted(pair, feeToken, rawAmount, usdcReceived, msg.sender, callerBonus);
    }

    // =========================================================
    // VIEW HELPERS
    // =========================================================

    /// @notice Preview what a conversion would yield right now.
    ///         Returns 0 if conditions not met (cooldown, no TWAP, below min).
    function previewConversion(
        address pair,
        address feeToken
    ) external view returns (
        uint256 rawAmount,
        uint256 expectedUsdc,
        uint256 callerBonus,
        uint256 vaultUsdc,
        bool    convertible
    ) {
        if (feeToken == USDC) return (0, 0, 0, 0, false);
        if (block.timestamp < lastConversion[pair][feeToken] + CONVERSION_COOLDOWN)
            return (0, 0, 0, 0, false);

        rawAmount = IILShieldVaultExtended(vault).rawFeeBalances(pair, feeToken);
        if (rawAmount == 0) return (0, 0, 0, 0, false);

        address usdcFeeTokenPair = IFactory(factory).getPair(feeToken, USDC);
        if (usdcFeeTokenPair == address(0)) return (rawAmount, 0, 0, 0, false);

        try ITWAPOracle(twapOracle).getTWAPForTokens(usdcFeeTokenPair, feeToken)
            returns (uint256 price)
        {
            if (price == 0) return (rawAmount, 0, 0, 0, false);
            expectedUsdc = (rawAmount * price) / 1e18;
        } catch {
            return (rawAmount, 0, 0, 0, false);
        }

        if (expectedUsdc < MIN_CONVERSION_USDC) return (rawAmount, expectedUsdc, 0, 0, false);

        callerBonus = (expectedUsdc * CALLER_BONUS_BPS) / BPS_DENOMINATOR;
        if (callerBonus > MAX_CALLER_BONUS) callerBonus = MAX_CALLER_BONUS;

        vaultUsdc   = expectedUsdc - callerBonus;
        convertible = true;
    }

    /// @notice Seconds until this (pair, token) can be converted again.
    function cooldownRemaining(
        address pair,
        address feeToken
    ) external view returns (uint256) {
        uint256 nextAllowed = lastConversion[pair][feeToken] + CONVERSION_COOLDOWN;
        if (block.timestamp >= nextAllowed) return 0;
        return nextAllowed - block.timestamp;
    }

    // =========================================================
    // ADMIN
    // =========================================================

    

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    /// @dev Read token0 from a pair without importing Pair.sol
    function _getPairToken0(address pair) internal view returns (address token0) {
        (bool success, bytes memory data) = pair.staticcall(
            abi.encodeWithSignature("token0()")
        );
        if (!success || data.length == 0) revert PairNotRegistered();
        token0 = abi.decode(data, (address));
    }

    function _getPairToken1(address pair) internal view returns (address token1) {
        (bool success, bytes memory data) = pair.staticcall(
            abi.encodeWithSignature("token1()")
        );
        if (!success || data.length == 0) revert PairNotRegistered();
        token1 = abi.decode(data, (address));
    }
}