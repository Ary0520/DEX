// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Router
/// @notice Fixes: double-cap removed (cap only in Vault), partial withdrawal via
///         reducePosition(), fee split matches spec (75/15/10), payout from Vault
///         directly in USDC, to-address validation, updatable system addresses.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
    function getPairConfig(address pair) external view returns (
        uint256 vaultFeeBps,
        uint256 treasuryFeeBps,
        uint256 lpFeeBps,
        uint256 maxCoverageBps
    );
}

interface IPair {
    function mint(address to) external returns (uint256);
    function burn(address to) external returns (uint256, uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function lpFeeBps() external view returns (uint256);
}

interface IILShieldVault {
    function depositFees(address pair, address feeToken, uint256 amount) external;
    function updateExposure(address pair, uint256 newTotalExposureUSDC) external;
    function getExposure(address pair) external view returns (uint256);
    function requestPayout(
        address pair,
        address user,
        uint256 netIL,
        uint256 userLiquidityValue,
        uint256 tierCeilingBps,
        uint256 secondsInPool
    ) external returns (uint256);
}

interface IILPositionManager {
    struct Position {
        uint256 liquidity;
        uint256 valueAtDeposit;
        uint256 timestamp;
    }
    function recordDeposit(address pair, address user, uint256 liquidity, uint256 depositValue) external;
    function reducePosition(address pair, address user, uint256 liquidityRemoved)
        external returns (uint256 proportionalValue, uint256 positionTimestamp);
    function getPosition(address pair, address user) external view returns (Position memory);
}

interface ITWAPOracle {
    function getTWAPForTokens(address pair, address tokenA) external view returns (uint256);
}

contract Router is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // CONSTANTS
    // =========================================================

    uint256 public constant MIN_LOCK           = 7 days;

    // Fee split in bps of the 0.3% total fee
    // 0.3% total = 7500 bps of swap going to LP (via pair), 
    // + we take a separate 0.3% on top for IL + treasury
    // Spec: 75% to LP, 15% to vault, 10% to treasury
    // We implement as: 0.3% extra fee on amountIn split 15/10 (vault/treasury)
    // LP fee is handled natively by the Pair contract (0.3% invariant)
    uint256 public constant FEE_DENOMINATOR    = 10000;
    // =========================================================
    // STATE
    // =========================================================

    address public immutable factory;
    address public ilVault;
    address public positionManager;
    address public twapOracle;
    address public treasury;
    address public owner;

    // =========================================================
    // ERRORS
    // =========================================================

    error Router__Expired();
    error Router__ZeroAddress();
    error Router__PairNotFound();
    error Router__SlippageExceeded();
    error Router__AmountZero();
    error Router__NotOwner();
    error Router__InvalidPath();

    // =========================================================
    // EVENTS
    // =========================================================

    event LiquidityAdded(address indexed pair, address indexed to, uint256 liquidity);
    event LiquidityRemoved(address indexed pair, address indexed to, uint256 amountA, uint256 amountB, uint256 ilPayout);
    event SwapExecuted(address indexed pair, address indexed to, uint256 amountIn, uint256 amountOut);
    event SystemAddressUpdated(string indexed key, address newAddress);

    // =========================================================
    // MODIFIERS
    // =========================================================

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Router__Expired();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Router__NotOwner();
        _;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(
        address _factory,
        address _vault,
        address _pm,
        address _oracle,
        address _treasury
    ) {
        if (_factory  == address(0)) revert Router__ZeroAddress();
        if (_vault    == address(0)) revert Router__ZeroAddress();
        if (_pm       == address(0)) revert Router__ZeroAddress();
        if (_oracle   == address(0)) revert Router__ZeroAddress();
        if (_treasury == address(0)) revert Router__ZeroAddress();

        factory        = _factory;
        ilVault        = _vault;
        positionManager = _pm;
        twapOracle     = _oracle;
        treasury       = _treasury;
        owner          = msg.sender;
    }

    // =========================================================
    // ADD LIQUIDITY
    // =========================================================

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        if (to == address(0)) revert Router__ZeroAddress();

        (amountA, amountB) = _addLiquidity(
            tokenA, tokenB,
            amountADesired, amountBDesired,
            amountAMin, amountBMin
        );

        address pair = IFactory(factory).getPair(tokenA, tokenB);

        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);

        liquidity = IPair(pair).mint(to);

        // ── Record IL position ────────────────────────────────
        uint256 price    = _getSafePrice(pair, tokenA);
        uint256 depositValue = (amountA * price) / 1e18 + amountB;

        IILPositionManager(positionManager).recordDeposit(
            pair, to, liquidity, depositValue
        );

        // Increase exposure by this deposit's value
        uint256 currentExposure = IILShieldVault(ilVault).getExposure(pair);
        IILShieldVault(ilVault).updateExposure(pair, currentExposure + depositValue);

        emit LiquidityAdded(pair, to, liquidity);
    }

    // =========================================================
    // REMOVE LIQUIDITY
    // =========================================================

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) nonReentrant returns (uint256 amountA, uint256 amountB) {
        if (to == address(0)) revert Router__ZeroAddress();
        if (liquidity == 0)   revert Router__AmountZero();

        address pair = IFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert Router__PairNotFound();

        // ── 1. Reduce position FIRST (get proportional deposit value) ─────
        // This handles partial withdrawals correctly
        (uint256 proportionalDepositValue, uint256 positionTimestamp) =
            IILPositionManager(positionManager).reducePosition(pair, msg.sender, liquidity);

        // ── 2. Execute withdrawal ─────────────────────────────────────────
        (amountA, amountB) = _removeLiquidity(
            tokenA, tokenB, liquidity, amountAMin, amountBMin, to
        );

        // ── 3. IL payout (only if lock period satisfied) ──────────────────
        uint256 ilPayout = 0;

        if (positionTimestamp != 0 && block.timestamp >= positionTimestamp + MIN_LOCK) {
            uint256 price    = _getSafePrice(pair, tokenA);
            uint256 lpValue  = (amountA * price) / 1e18 + amountB;

            uint256 netIL = proportionalDepositValue > lpValue
                ? proportionalDepositValue - lpValue
                : 0;

            if (netIL > 0) {
                // Read coverage cap for this pair's tier
                (,,, uint256 maxCoverageBps) =
                    IFactory(factory).getPairConfig(pair);

                ilPayout = IILShieldVault(ilVault).requestPayout(
                    pair,
                    to,
                    netIL,
                    lpValue,
                    maxCoverageBps,
                    block.timestamp - positionTimestamp
                );
            }
        }

        // Decrease exposure by the proportional deposit value that just left
        uint256 currentExposure = IILShieldVault(ilVault).getExposure(pair);
        uint256 newExposure = currentExposure > proportionalDepositValue
            ? currentExposure - proportionalDepositValue
            : 0;
        IILShieldVault(ilVault).updateExposure(pair, newExposure);

        emit LiquidityRemoved(pair, to, amountA, amountB, ilPayout);


        /////What this does////
        
        //LP adds liquidity ($1000 value)→ exposure goes from $0 → $1000
        //Another LP adds ($500 value) → exposure goes from $1000 → $1500
        //First LP removes 50% of their position ($500 proportional value) → exposure goes from $1500 → $1000
        //CoverageCurve now sees:
        //  vault reserve = $X
        //  total exposure = $1000
        //→ calculates real vault health ratio

    }

    // =========================================================
    // SWAP
    // =========================================================

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) nonReentrant returns (uint256[] memory amounts) {
        if (path.length < 2)  revert Router__InvalidPath();
        if (to == address(0)) revert Router__ZeroAddress();
        if (amountIn == 0)    revert Router__AmountZero();

        address inputToken = path[0];
        address pair = IFactory(factory).getPair(path[0], path[1]);
        if (pair == address(0)) revert Router__PairNotFound();

        // ── Read fee config live from Factory (tier-aware) ────────────────
        (uint256 vaultFeeBps, uint256 treasuryFeeBps,,) =
            IFactory(factory).getPairConfig(pair);

        uint256 vaultFee    = (amountIn * vaultFeeBps)    / FEE_DENOMINATOR;
        uint256 treasuryFee = (amountIn * treasuryFeeBps) / FEE_DENOMINATOR;
        uint256 amountForSwap = amountIn - vaultFee - treasuryFee;

        // ── Compute amounts ───────────────────────────────────────────────
        amounts = getAmountsOut(amountForSwap, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert Router__SlippageExceeded();

        // ── Transfer: swap portion to pair ────────────────────────────────
        IERC20(inputToken).safeTransferFrom(msg.sender, pair, amountForSwap);

        // ── Transfer: vault fee ───────────────────────────────────────────
        IERC20(inputToken).safeTransferFrom(msg.sender, ilVault, vaultFee);
        IILShieldVault(ilVault).depositFees(pair, inputToken, vaultFee);

        // ── Transfer: treasury fee ────────────────────────────────────────
        IERC20(inputToken).safeTransferFrom(msg.sender, treasury, treasuryFee);

        // ── Execute swap ──────────────────────────────────────────────────
        _swap(amounts, path, to);

        emit SwapExecuted(pair, to, amountIn, amounts[amounts.length - 1]);

        return amounts;
    }

    // =========================================================
    // VIEW
    // =========================================================

    function getAmountsOut(
        uint256 amountIn,
        address[] memory path
    ) public view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; i++) {
            address pair = IFactory(factory).getPair(path[i], path[i + 1]);
            if (pair == address(0)) revert Router__PairNotFound();

            (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
            address token0 = IPair(pair).token0();
            uint256 fee = IPair(pair).lpFeeBps();

            (uint256 rIn, uint256 rOut) = path[i] == token0
                ? (uint256(r0), uint256(r1))
                : (uint256(r1), uint256(r0));

            amounts[i + 1] = _getAmountOut(amounts[i], rIn, rOut, fee);
        }
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        public pure returns (uint256 amountB)
    {
        if (reserveA == 0 || reserveB == 0) revert Router__PairNotFound();
        amountB = (amountA * reserveB) / reserveA;
    }

    // =========================================================
    // ADMIN — updatable system addresses
    // =========================================================

    function setILVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert Router__ZeroAddress();
        ilVault = _vault;
        emit SystemAddressUpdated("ilVault", _vault);
    }

    function setPositionManager(address _pm) external onlyOwner {
        if (_pm == address(0)) revert Router__ZeroAddress();
        positionManager = _pm;
        emit SystemAddressUpdated("positionManager", _pm);
    }

    function setTWAPOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert Router__ZeroAddress();
        twapOracle = _oracle;
        emit SystemAddressUpdated("twapOracle", _oracle);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert Router__ZeroAddress();
        treasury = _treasury;
        emit SystemAddressUpdated("treasury", _treasury);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Router__ZeroAddress();
        owner = newOwner;
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    function _addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        address pair = IFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = IFactory(factory).createPair(tokenA, tokenB);
        }

        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        address token0 = IPair(pair).token0();

        (uint256 rA, uint256 rB) = tokenA == token0
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));

        if (rA == 0 && rB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, rA, rB);
            if (amountBOptimal <= amountBDesired) {
                amountA = amountADesired;
                amountB = amountBOptimal;
            } else {
                uint256 amountAOptimal = quote(amountBDesired, rB, rA);
                amountA = amountAOptimal;
                amountB = amountBDesired;
            }
        }

        if (amountA < amountAMin || amountB < amountBMin) revert Router__SlippageExceeded();
    }

    function _removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to
    ) internal returns (uint256 amountA, uint256 amountB) {
        address pair = IFactory(factory).getPair(tokenA, tokenB);

        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IPair(pair).burn(to);

        address token0 = IPair(pair).token0();
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);

        if (amountA < amountAMin) revert Router__SlippageExceeded();
        if (amountB < amountBMin) revert Router__SlippageExceeded();
    }

    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal {
        for (uint256 i = 0; i < path.length - 1; i++) {
            address input  = path[i];
            address output = path[i + 1];
            address pair   = IFactory(factory).getPair(input, output);
            address token0 = IPair(pair).token0();

            uint256 amountOut = amounts[i + 1];
            (uint256 out0, uint256 out1) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));

            address to = i < path.length - 2
                ? IFactory(factory).getPair(output, path[i + 2])
                : _to;

            IPair(pair).swap(out0, out1, to);
        }
    }

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 amountOut) {
        if (amountIn  == 0) revert Router__AmountZero();
        if (reserveIn == 0 || reserveOut == 0) revert Router__PairNotFound();

        // feeBps e.g. 30 = 0.30%, 5 = 0.05%
        // amountInWithFee = amountIn * (10000 - feeBps)
        // amountOut = amountInWithFee * reserveOut / (reserveIn * 10000 + amountInWithFee)
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        amountOut = (amountInWithFee * reserveOut)
            / (reserveIn * 10000 + amountInWithFee);
    }

    /// @notice Gets price from TWAP oracle, falls back to spot only if TWAP unavailable
    function _getSafePrice(address pair, address tokenA) internal view returns (uint256 price) {
        try ITWAPOracle(twapOracle).getTWAPForTokens(pair, tokenA) returns (uint256 twapPrice) {
            if (twapPrice > 0) return twapPrice;
        } catch {}

        // Spot fallback — used ONLY for deposit recording, never for payout calculation
        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        address token0 = IPair(pair).token0();

        if (r0 == 0 || r1 == 0) return 1e18;

        price = tokenA == token0
            ? uint256(r1) * 1e18 / uint256(r0)
            : uint256(r0) * 1e18 / uint256(r1);
    }
}