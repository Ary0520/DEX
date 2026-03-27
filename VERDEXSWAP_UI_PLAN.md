# VerdexSwap — Complete UI Plan

> This is a plan document, not a design spec. It covers copy, information architecture, flow, and feature completeness for both the Landing Page and the App (Features Page). Every section is grounded in what the contracts actually do and what top DeFi protocols (Uniswap, Aerodrome, Pendle, Camelot, Curve) have proven works in production.

---

## PART 1 — LANDING PAGE

The landing page has one job: convert a skeptical DeFi user into someone who connects their wallet. Every section must earn the next scroll.

---

### SECTION 1 — NAV

Left: VerdexSwap logo + wordmark
Center: Docs | How It Works | IL Shield | Pools | Blog
Right: [Launch App] button (primary CTA, always visible)

Behavior: sticky on scroll, transparent over hero, solid background after first scroll.

---

### SECTION 2 — HERO

**Headline (H1):**
"Swap freely. Earn fairly. Sleep safely."

**Sub-headline:**
"The first DEX that pays you back when impermanent loss hits. Every swap seeds a real, funded protection vault — no token printing, no frozen withdrawals, no fine print."

**CTA row:**
- [Launch App] — primary
- [Read the Docs] — secondary ghost button

**Trust signal strip below CTAs (small text, inline):**
"Deployed on Arbitrum Sepolia · Contracts verified on Etherscan · Built on battle-tested AMM math"

**Hero visual:**
Animated diagram showing the flywheel: Swap → Fees → IL Shield Vault → LP Payout → back to Swap. Not a static image. Motion communicates the self-sustaining machine concept.

---

### SECTION 3 — LIVE PROTOCOL STATS BAR

Full-width strip, dark background, 4 animated counters:

| Total Volume | Total Value Locked | IL Payouts Issued | Active Pools |
|---|---|---|---|
| $X,XXX,XXX | $X,XXX,XXX | $XX,XXX | XX |

These pull from on-chain data. If the protocol is early, show "Bootstrap Phase" badge next to TVL with a tooltip explaining the protocol fee is off and LPs earn 100% of fees.

---

### SECTION 4 — THE PROBLEM (AGITATION)

**Headline:** "Every other DEX is quietly costing you money."

Three cards, side by side:

**Card 1 — Impermanent Loss**
Icon: downward arrow eating into a wallet
Title: "You earn fees. You lose more."
Body: "When prices move, AMMs rebalance your position automatically. The result: you end up with less than if you'd just held. Research shows most LPs on major DEXs earn negative real returns after IL."

**Card 2 — Sandwich Attacks**
Icon: two arrows squeezing a transaction
Title: "Bots eat your trades."
Body: "Your transaction sits in a public mempool. Bots see it, jump in front, push the price up, let your trade execute worse, then sell. In March 2026, one trader lost ~$50M to a single sandwich attack on SushiSwap."

**Card 3 — Fake IL Protection**
Icon: broken shield
Title: "Bancor promised this. Then froze withdrawals."
Body: "Protocols that claimed IL protection either printed their own token to pay you (diluting everyone) or froze withdrawals the moment markets got rough. VerdexSwap does neither."

---

### SECTION 5 — THE SOLUTION (IL SHIELD FEATURE SPOTLIGHT)

**Headline:** "Introducing IL Shield — real protection, funded by real trading."

**Sub-headline:** "Not a promise. Not a token. A live, on-chain vault that grows with every swap and pays you back in USDC when you exit."

Three-column layout:

**Column 1 — How it's funded**
Icon: flowing coins
"Every swap on VerdexSwap automatically routes a portion of the input to the IL Shield Vault. It happens in the same transaction, in code. No one can skip it."

**Column 2 — How coverage grows**
Icon: time + shield growing
"The longer you stay in a pool, the more coverage you earn. Coverage starts at ~11% after 7 days and grows toward 98% of your tier's ceiling after 8 months. Loyal LPs are rewarded."

**Column 3 — How you get paid**
Icon: USDC coin with checkmark
"When you withdraw, the Router automatically checks your IL. If you qualify, USDC lands in your wallet in the same transaction. No claim form. No waiting. No separate interface."

**Coverage schedule visual (table or chart):**
| Time in Pool | Coverage (% of tier ceiling) |
|---|---|
| 7 days | ~11% |
| 30 days | ~39% |
| 60 days | ~63% |
| 90 days | ~78% |
| 120 days | ~87% |
| 180 days | ~95% |
| 240 days+ | ~98% |

Small note below: "Coverage ceiling depends on pool tier: Volatile pools up to 75%, Blue Chip up to 50%, Stable up to 15%."

---

### SECTION 6 — THREE-TIER POOL SYSTEM

**Headline:** "Not all pools are the same. VerdexSwap knows the difference."

**Sub-headline:** "Every pool is automatically classified into a tier. The tier determines fees, IL coverage, and how the vault is funded — all handled on-chain, no configuration needed."

Three-column tier cards:

**Stable Tier**
Examples: USDC/USDT, DAI/USDC
Vault fee: 0.03% | Treasury: 0.02% | LP fee: 0.05%
IL Coverage: up to 15%
"Stable pairs have near-zero IL. Lower fees, modest protection — a fair trade."

**Blue Chip Tier**
Examples: ETH/USDC, BTC/ETH
Vault fee: 0.10% | Treasury: 0.05% | LP fee: 0.20%
IL Coverage: up to 50%
"Major assets with moderate volatility. Meaningful protection where it matters."

**Volatile Tier**
Examples: Any emerging token pair
Vault fee: 0.15% | Treasury: 0.10% | LP fee: 0.30%
IL Coverage: up to 75%
"High risk, highest protection. The vault charges more per swap and covers more on exit."

Small note: "Total fees are hard-capped at 2% in the Factory contract. This is enforced in code."

---

### SECTION 7 — HOW IT WORKS (STEP-BY-STEP FLOW)

**Headline:** "Simple for users. Sophisticated under the hood."

Two tabs: [For Traders] [For Liquidity Providers]

**For Traders tab:**
1. Connect your wallet
2. Select tokens and enter amount
3. Router reads your pool's tier and splits fees automatically
4. Slippage tolerance enforced — if the swap would give you less than you asked for, it reverts
5. Tokens arrive in your wallet

**For Liquidity Providers tab:**
1. Connect your wallet and select a pool
2. Deposit tokens — Router records your entry value using TWAP pricing
3. Earn 0.30% on every swap through your pool
4. Your IL coverage grows every day you stay in
5. When you withdraw (after 7+ days), IL payout is calculated and sent in USDC automatically

---

### SECTION 8 — TWAP ORACLE & SECURITY

**Headline:** "Prices you can trust. Security you can verify."

Two-column layout:

**Left — TWAP Oracle**
"VerdexSwap uses a Time-Weighted Average Price oracle that averages prices over 30 minutes to 8 hours. A hacker cannot flash-loan their way to a fake IL claim — they'd need to hold a manipulated price for 30+ minutes, which costs more than any possible gain."

Key specs:
- Minimum window: 30 minutes
- Maximum staleness: 8 hours
- Permissionless: anyone can update it
- Self-maintaining: FeeConverter callers auto-update and earn 0.1% bonus

**Right — Security Architecture**
Checklist style:
- Reentrancy locks on every state-changing function
- OpenZeppelin ReentrancyGuard on Router, Vault, FeeConverter
- Checks-Effects-Interactions pattern throughout
- Solidity 0.8.x overflow protection
- SafeERC20 for all token transfers
- Constant-product invariant enforced on every swap
- 7-day minimum lock prevents flash-deposit attacks
- Per-user payout cap: 20% of LP value
- Per-event pool cap: 5% of vault reserve

---

### SECTION 9 — FEE CONVERTER FLYWHEEL

**Headline:** "A self-sustaining machine. No team required."

Visual: circular flywheel diagram

Steps in the flywheel:
1. Traders swap → fees accumulate as raw tokens in the vault
2. Anyone calls FeeConverter → raw tokens swap to USDC
3. Caller earns 0.1% bonus (up to 50 USDC) — financially incentivized
4. USDC credited to vault: 50% to staker yield, 50% to IL reserve
5. More USDC in vault → more IL coverage available
6. More coverage → more attractive to LPs → more liquidity → more swaps → back to step 1

"No keeper infrastructure. No team intervention. The protocol maintains itself."

---

### SECTION 10 — IL VAULT STAKING

**Headline:** "Earn real yield as an insurance provider."

**Sub-headline:** "Deposit USDC into any pool's vault. Earn 50% of all vault fees from that pool's trading activity. Your capital backs LP protection — and you're compensated for it."

Three feature points:

**Real yield, not emissions**
"Staker rewards come from organic swap fees — not token printing. If the pool trades, you earn."

**14-day cooldown (by design)**
"Stakers must request unstake and wait 14 days before withdrawing. This is not a bug — it's the lesson from Bancor. No one can drain the vault in a panic. Stakers know this before they enter."

**Loss absorption (last resort)**
"Stakers are the last line of defense. Fee revenue absorbs payouts first. Only if payouts exceed the fee buffer does staker capital take a haircut — and only proportionally."

CTA: [Stake USDC in a Pool] → links to app

---

### SECTION 11 — PROTOCOL FEE TRANSPARENCY

**Headline:** "LP-first from day one."

"The protocol fee is currently OFF. Every basis point of the 0.30% LP fee stays with liquidity providers at launch. Early LPs capture the full fee with zero protocol dilution.

The fee will only be considered for activation after meaningful TVL milestones, through a transparent governance process with advance community notice. Even when active, total fees are hard-capped at 2% in the Factory contract — enforced in code, not policy."

---

### SECTION 12 — COMPETITOR COMPARISON TABLE

**Headline:** "Where others failed. Where we're different."

| Feature | Uniswap V2 | Bancor | VerdexSwap |
|---|---|---|---|
| IL Protection | None | Yes (then froze) | Yes — funded by real fees |
| Payout currency | N/A | BNT (printed token) | USDC |
| Withdrawal during crisis | Always open | Frozen | Always open |
| Oracle manipulation resistance | Spot price | Spot price | TWAP (30min min window) |
| Self-sustaining vault | N/A | No | Yes — FeeConverter flywheel |
| Protocol fee at launch | Yes | Yes | No — LP-first bootstrap |
| Staker cooldown | N/A | None (bank run risk) | 14 days (hardcoded) |

---

### SECTION 13 — SOCIAL PROOF / TRUST

**Headline:** "Built in public. Verified on-chain."

- Contract addresses with Etherscan links (Factory, Router, ILShieldVault, TWAPOracle, FeeConverter)
- GitHub link to open-source contracts
- Audit badge (when available) — placeholder: "Audit in progress"
- "All logic runs in smart contracts. Anyone can verify every payout, every fee, every vault balance."

Community links: Twitter/X | Discord | Telegram | Mirror/Blog

---

### SECTION 14 — FAQ

Accordion-style, 8 questions:

1. What is impermanent loss and why does it matter?
2. How is VerdexSwap's IL protection different from Bancor's?
3. Do I need to do anything to claim IL protection?
4. What happens if the vault runs out of USDC?
5. What is the 7-day minimum lock?
6. Can I withdraw at any time even if the vault is stressed?
7. What is the FeeConverter and why does it matter?
8. Is the protocol fee currently active?

---

### SECTION 15 — FOOTER

Left: Logo + tagline "Swap freely. Earn fairly. Sleep safely."
Center: Links — Docs | GitHub | Audit | Blog | Terms | Privacy
Right: Social icons — Twitter/X | Discord | Telegram
Bottom: "VerdexSwap is experimental software. Use at your own risk. Not financial advice."

---
---

## PART 2 — APP (FEATURES PAGE)

The app is where users actually interact with the protocol. Navigation is persistent. Every page has a clear primary action.

---

### APP NAV (PERSISTENT)

Left: Logo
Center tabs: Swap | Pools | Earn (Staking) | Portfolio | Analytics
Right: [Connect Wallet] / wallet address + balance when connected + network badge (Arbitrum)

---

### PAGE 1 — SWAP

**Layout:** centered card, max-width ~480px, rest of screen is background

**Swap card anatomy:**

Top row: "Swap" tab active | "Limit" tab (future) | Settings gear icon (slippage, deadline)

**Input field (FROM):**
- Token selector button (shows token logo + symbol) — right side
- Amount input — left side
- Row above: "Balance: X.XX [MAX] [50%]"
- Row below: "≈ $X,XXX.XX"

**Swap direction arrow** (clickable, reverses tokens)

**Output field (TO):**
- Token selector button — right side
- Amount (read-only, calculated) — left side
- Row above: "Balance: X.XX"
- Row below: "≈ $X,XXX.XX (Price impact: -0.XX%)" — price impact colored green/yellow/red

**Details panel (expandable accordion below output):**
- Rate: 1 ETH = X,XXX USDC
- Price impact: X.XX%
- Minimum received: X.XX USDC (after slippage)
- Vault fee: X.XX USDC (0.15% → IL Shield)
- Treasury fee: X.XX USDC (0.10%)
- LP fee: X.XX USDC (0.30%)
- Route: TOKEN → USDC (single hop shown)
- Pool tier: [Volatile] badge

**CTA button (contextual):**
- No wallet: "Connect Wallet"
- Wrong network: "Switch to Arbitrum"
- Insufficient balance: "Insufficient ETH balance"
- Valid: "Swap" (primary green)
- Pending approval: "Approving... (1/2)"
- Pending swap: "Swapping..."

**Slippage settings modal (gear icon):**
- Auto / 0.1% / 0.5% / 1.0% / Custom input
- Transaction deadline: 20 min default, editable
- Warning if slippage > 5%: "High slippage — your trade may be frontrun"

---

### PAGE 2 — POOLS

**Layout:** full-width table with filter/search bar at top

**Header row:**
"Pools" title | [+ Create Pool] button | Search bar | Filter: [All] [Stable] [Blue Chip] [Volatile]

**Pool table columns:**
Pool (token pair logos + symbols) | Tier badge | TVL | 24h Volume | 7d Fees | APR (fee APR) | IL Coverage | [Add Liquidity]

**Pool row expanded (click to expand):**
- Reserve breakdown: X TOKEN0 / X TOKEN1
- Your position (if connected): X LP tokens | $X,XXX value | X days in pool | Current IL coverage: XX%
- Vault health: reserve $X,XXX | utilization XX%
- [Add Liquidity] [Remove Liquidity] [View on Etherscan]

**Add Liquidity modal:**
- Token A input + Token B input (auto-calculated ratio)
- "Optimal ratio" helper: shows how much of each token to deposit
- Slippage tolerance for liquidity
- Estimated LP tokens to receive
- IL coverage preview: "After 30 days: ~39% of tier ceiling covered"
- [Add Liquidity] button → approval flow → confirm

**Remove Liquidity modal:**
- LP token amount input (or slider: 25% / 50% / 75% / MAX)
- Estimated Token A + Token B to receive
- IL payout estimate: "Estimated IL payout: ~$XX.XX USDC" (if eligible)
  - If < 7 days: "IL protection unlocks in X days"
  - If vault stressed: "Vault utilization: XX% — coverage may be reduced"
- [Remove Liquidity] button

---

### PAGE 3 — EARN (IL VAULT STAKING)

**Layout:** two-column — left: staking interface, right: vault stats

**Left — Stake USDC:**

Pool selector dropdown (shows all pools with vault stats)

Selected pool card:
- Pool: ETH/USDC | Tier: Blue Chip
- Vault reserve: $X,XXX USDC
- Staker APR: XX.XX% (from fee revenue)
- Your stake: $X,XXX USDC | Your share: X.XX%
- Pending rewards: $XX.XX USDC [Harvest]

Stake input:
- USDC amount input
- "Balance: X,XXX USDC [MAX]"
- [Stake USDC] button

Unstake section:
- If no request: [Request Unstake] button
  - Warning: "14-day cooldown begins immediately. You cannot cancel this."
- If request pending: "Unstake available in: X days X hours" + progress bar
- If cooldown complete: [Withdraw X USDC] button

**Right — Vault Stats:**
- Total vault reserve: $X,XXX
- Staker deposits: $X,XXX
- Fee deposits: $X,XXX
- Total paid out (lifetime): $X,XXX
- Utilization: XX% (colored: green <50%, yellow 50-80%, red >80%)
- Circuit breaker status: Active / Inactive
- Outstanding exposure: $X,XXX
- Vault health ratio: X.XXx (reserve / exposure)

Coverage curve chart: interactive line chart showing coverage % vs days in pool for this tier.

---

### PAGE 4 — PORTFOLIO

**Layout:** full-width dashboard

**Top row — summary cards:**
- Total LP Value: $X,XXX
- Total IL Exposure: $X,XXX
- Total IL Payouts Received: $X,XXX
- Staking Rewards Earned: $X,XXX

**LP Positions table:**
Pool | Entry Value | Current Value | IL ($ and %) | Days in Pool | Coverage % | Est. Payout | Actions

Each row expandable:
- Entry timestamp
- Entry price (TWAP at deposit)
- Current TWAP price
- Coverage schedule progress bar
- [Remove Liquidity] shortcut

**Staking Positions table:**
Pool | Staked USDC | Current Value | Earned Fees | APR | Unstake Status | Actions

**Transaction history:**
Filterable by: Swaps | Liquidity | Staking | IL Payouts
Columns: Date | Type | Tokens | Amount | IL Payout | Tx Hash

---

### PAGE 5 — ANALYTICS

**Layout:** full-width dashboard, charts prominent

**Protocol-level stats:**
- TVL over time (line chart)
- 24h / 7d / 30d volume (bar chart)
- Total fees generated (cumulative line)
- Total IL payouts issued (cumulative line)
- Active pools count
- Unique LPs count

**Per-pool analytics (select pool from dropdown):**
- Reserve history
- Volume history
- Fee APR history
- Vault reserve vs exposure (health ratio over time)
- IL payout history

**FeeConverter activity:**
- Last conversion: X hours ago
- Total USDC converted: $X,XXX
- Next eligible conversion: X minutes

---

### GLOBAL APP COMPONENTS

**Wallet connection modal:**
- MetaMask | WalletConnect | Coinbase Wallet | Rabby
- Network check: if not on Arbitrum, show "Switch Network" prompt

**Transaction status toast (bottom-right):**
- Pending: spinner + "Swapping ETH → USDC..."
- Confirmed: checkmark + "Swap confirmed" + Etherscan link
- Failed: X + error message + retry option

**IL Protection status badge (shown on LP positions):**
- Green shield: "Protected — XX% coverage active"
- Yellow shield: "Accruing — X days until full coverage"
- Grey shield: "Locked — X days remaining"

**Vault health indicator (shown on pool cards and staking page):**
- Green: utilization < 50%
- Yellow: 50-80% — "Circuit breaker active, coverage halved"
- Red: > 80% — "Vault paused — IL payouts temporarily suspended"

**Pool tier badge:**
- Stable: blue badge
- Blue Chip: purple badge
- Volatile: orange badge

---

## COPY PRINCIPLES

These apply across both landing page and app:

1. Never say "impermanent loss" without immediately explaining it in plain English.
2. Always show dollar values alongside token amounts.
3. Never hide fees — show the full breakdown before any transaction.
4. When vault is stressed, be transparent — show utilization and what it means.
5. The 14-day staker cooldown must be explained before anyone stakes, not after.
6. IL payout estimates should always show the caveat: "estimate based on current vault health."
7. "USDC" not "stablecoins" — be specific about what users receive.
8. Avoid "yield" without context — always show where the yield comes from (swap fees, not emissions).

---

## INFORMATION HIERARCHY SUMMARY

**Landing page goal:** Explain the IL Shield problem/solution clearly enough that a skeptical DeFi user trusts the protocol before they connect a wallet.

**App goal:** Make every action (swap, add liquidity, remove liquidity, stake) completable in under 3 clicks with full fee and IL transparency at every step.

**The single most important UI element in the entire product:** The IL payout estimate shown on the Remove Liquidity modal. This is where the protocol's core promise becomes tangible. It must show: entry value, current value, IL amount, coverage %, estimated USDC payout, and vault health — all before the user confirms.
