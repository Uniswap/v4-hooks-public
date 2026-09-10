# Methodology

Block by block, a small pool running the fee design under test competes for
order flow against the rest of the market. Volume won, fees collected, and
adverse selection suffered are outputs. Market flow, prices, and gas are inputs
calibrated from data. This page defines each piece and gives the reason it is
built that way.

## The two venues

**Our pool.** $10M TVL, concentrated ±20bp around the peg. Its fee is set by the
design under test: a flat fee, the naive directional hook, StablePair Hook at
any (optimalFeeE6, k, TM) configuration, or the flipped design that charges
more for swaps moving away from the reference than for corrective swaps.

**Rest of market.** A single stand-in venue with $50M at ±20bp, equal to $25B of
full-range v2 depth, calibrated to the execution-cost curve measured on real
USDC/USDT trades. It charges 0.07bp, the posted fee of the largest real pool for
the pair. It is re-synced to the fair price at the top of every block, so it is
correctly priced when flow arrives and offers no arbitrage.

A deep stand-in rather than an equal-sized rival pool, because an equal-sized
rival would hand the pool under test about half of all flow by construction,
which is not the position of any new pool. With a deep venue held at fair, our
pool's share of flow is an output of routing competition.

Its depth comes from the slope of the execution-cost-vs-size curve on real
USDC/USDT trades, which pins how deep the outside option is. Depth is the
invariant: $50M at ±20bp, $500M at ±2% and $25B full-range are the same venue.

Its fee is the posted fee rather than the measured all-in cost, because the
impact curve's intercept includes gas and the router models gas separately.
Posted fee plus modeled gas reproduces the measured all-in cost without double-
counting.

Both pools sit at ±20bp because a concentrated range has to be wide relative to
the price process. With the range under roughly four standard deviations of the
peg wander, range-edge effects dominate and can invert results: at ±10bp several
comparisons flip sign from edge saturation alone, while at ±20bp they match the
wide-range limit. ±20bp is the tightest width that is safe for this pair's
process and the only width the published results are validated at. Other widths
run but are unvetted.

## Order flow

Built from 60 days of onchain USDC/USDT (Jun 18 to Aug 16, 2026).

**Retail.** 182,301 orders, $36.6M/day, arriving as a Poisson stream. Orders are
the transactions of eight retail-facing router contracts. Sizes are drawn from
the empirical distribution, one order per transaction, so a routed split counts
once. Direction is 50/50: retail is treated as noise flow, and net direction
lives in the fair-price path, which retail cannot move.

**Other flow.** A live pool also carries order flow that is not modeled here.
Modeling it as ordinary fee-paying volume would inflate every absolute number
while saying little about the difference between fee designs, which is what this
environment is for. So the order stream is retail plus the arbitrageur, and
findings are stated as relative performance between designs. The direction
result rests on which side of par a swap lands on, not on who sent it, so we
expect it to hold under flow the environment does not model, with a different
level of returns. The order stream is a single interface in the simulator, so
other flow can be added.

## Routing

Every order is split across the two venues for best execution net of gas: each
order maximizes output net of a fixed cost per route leg. The leg cost is
measured, 210k gas marginal, $0.35 at the window's median gas price. Real
routers are gas-aware: measured multi-leg transactions cluster at cheap gas. Our
pool's volume and share are outputs of this competition.

## Prices and arbitrage

The fair price is a two-factor Ornstein-Uhlenbeck process fitted to USDC/USDT:
an intraday factor (14h half-life, 1.4bp stationary width) plus a slow premium
factor (10d half-life, 4.5bp), simulated with exact transitions. Two factors
because one cannot carry both the intraday movement and the multi-day premium in
the data.

Volatility is a continuous multiplier on the price process, fitted to 576 days
of realized volatility. It is level-normalized so it redistributes variance over
time without adding any. Its long-run mean square is exactly one.

A fee-aware arbitrageur closes any gap between the pool and the fair price at
the end of each block. Arbitrage runs last, so each block ends near fair.

## Method

- Each run is a full 365-day path of 12-second blocks, 2.63M blocks per path.
- Every configuration is run on 128 independent paths, and the paths are
  identical across configurations, so every comparison is a seed-paired
  difference with a t-statistic. Raw pnl is dominated by which paths a run drew,
  and the pairing cancels that.
- **pnl** is the change in the pool's holdings over the path, fees included,
  valued at the final fair price. The static LP position's value depends only on
  the final price and the range, is identical across designs on the same path,
  and cancels in every paired comparison.
- The engine for StablePair Hook is a port of its Solidity fee calculation.
- The RNG draw order is frozen and every random stream is seeded, so the same
  seed and flags reproduce the same path and the same numbers on any machine.
