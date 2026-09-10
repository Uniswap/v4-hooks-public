"""The CEX-DEX arbitrageur.

Frictionless on the CEX side: infinitely deep at the true price ``p_star``, no
gas, no CEX fee. Fee-aware on the pool side: once per block the arb peeks the
strategy's quoted fee for its trade direction (a staticcall: no side effects),
and trades only if the dislocation exceeds the fee, pushing the pool's
post-fee marginal price exactly to ``p_star``.

Fees come from the strategy via the engine protocol (a peek is a
staticcall quote; state commits only on executed swaps).
"""

from __future__ import annotations

from dataclasses import dataclass

from ..core import swapmath as sm
from ..core.fixedpoint import ONE_E6, div_rounding_up
from ..core.pool import FeeQuote
from ..core.pool import price_to_sqrt_x96

MAX_FEE_E6 = 10_000     # 100 bp: mirrors StableStrategyBase.MAX_FEE_E6


class ArbInvariantError(RuntimeError):
    """A core arbitrage invariant was violated: the strategy is disqualified.

    Guards the quote/execute contract (a strategy must not quote one fee and be
    charged another) and the sim's economic sanity (the arb never trades at a
    loss). Both hold by construction for a correct strategy. This raises on any
    breach instead of silently producing a bogus score.
    """


# Violation tolerances (USD). Rounding dust is ~1e-6/trade; these only trip on
# a genuine breach, never on integer-rounding noise.
_PROFIT_TOL_USD = 0.01


@dataclass
class ArbResult:
    traded: bool
    zero_for_one: bool | None = None
    fee_e6: int = 0
    # Input leg in raw token units / SCALE. Diagnostic only: the unit is token0
    # for zero_for_one fills and token1 otherwise, un-converted, so it is a
    # near-parity mix (bounded by the pool's +-2% range). Never used in scoring.
    notional_usd: float = 0.0
    arb_profit_usd: float = 0.0     # arb net profit (after pool fee), at true prices
    lp_fee_usd: float = 0.0         # fee paid to the LP
    # True when the sized input was fully consumed. Note the arb sizes itself to
    # the CLAMPED target, so this stays True even when the range edge was hit:
    # compare price_after against the edge to detect that case.
    filled: bool = True
    price_after: float = 0.0
    # LP's signed inventory change from this fill (raw token units).
    lp_d0: int = 0
    lp_d1: int = 0
    # Raw integer legs of the executed swap (for exact afterSwap notifications).
    amount_in: int = 0
    amount_out: int = 0
    fee_raw: int = 0


def arb_step(sim, block: int, p_star: float, *, scale: int = 10**6) -> ArbResult:
    """Run the arb for one block against ``sim`` (mutates pool + engine state)."""
    pool, engine = sim.pool, sim.engine
    p0 = pool.price
    if p_star == p0:
        return ArbResult(traded=False, price_after=p0)

    zero_for_one = p_star < p0      # selling token0 lowers price toward p_star

    # Peek the fee for this direction without committing state (staticcall).
    peek = engine.before_swap(block, pool.sqrt_price_x96, zero_for_one, commit=False)
    f_e6 = peek.fee_e6
    # Engines are expected to quote inside [0, MAX_FEE_E6]. Raise rather
    # than silently widening the band past the documented cap, or, at
    # f_e6 == ONE_E6, dividing by zero below.
    if not 0 <= f_e6 <= MAX_FEE_E6:
        raise ArbInvariantError(
            f"quoted fee {f_e6} e6 outside the legal range [0, {MAX_FEE_E6}]")
    f = f_e6 / ONE_E6

    # Trade until the post-fee marginal price equals p_star (fee-widened band).
    if zero_for_one:
        p_target = p_star / (1 - f)
        if p_target >= p0:                      # inside the no-trade band
            return ArbResult(traded=False, price_after=p0)
    else:
        p_target = p_star * (1 - f)
        if p_target <= p0:
            return ArbResult(traded=False, price_after=p0)

    sqrt_target = price_to_sqrt_x96(p_target)
    sqrt_target = min(max(sqrt_target, pool.sqrt_lower_x96), pool.sqrt_upper_x96)
    if (zero_for_one and sqrt_target >= pool.sqrt_price_x96) or \
       (not zero_for_one and sqrt_target <= pool.sqrt_price_x96):
        return ArbResult(traded=False, price_after=p0)

    # Net input (after fee) to reach the target; gross up by the fee.
    if zero_for_one:
        net_in = sm.get_amount0_delta(sqrt_target, pool.sqrt_price_x96, pool.liquidity, True)
    else:
        net_in = sm.get_amount1_delta(pool.sqrt_price_x96, sqrt_target, pool.liquidity, True)
    if net_in <= 0:
        return ArbResult(traded=False, price_after=p0)
    gross_in = div_rounding_up(net_in * ONE_E6, ONE_E6 - f_e6)

    out = sim.swap(block, zero_for_one, gross_in)   # commits engine + strategy state

    # --- invariants (a correct strategy satisfies both by construction) ---
    # 1) quote == charge: the fee the arb peeked and sized against must equal
    #    the fee actually charged. beforeSwap is a view, so this always holds;
    #    asserting it turns any "quote one fee, charge another" breach into an error.
    if out.fee.fee_e6 != f_e6:
        raise ArbInvariantError(
            f"fee quoted at peek ({f_e6} e6) != fee charged at execution "
            f"({out.fee.fee_e6} e6)")

    paid = out.amount_in_consumed
    recv = out.amount_out
    if zero_for_one:        # arb pays token0, gets token1; LP takes token0, gives token1
        profit = (recv - paid * p_star) / scale
        lp_d0, lp_d1 = paid, -recv
    else:
        profit = (recv * p_star - paid) / scale
        lp_d0, lp_d1 = -recv, paid

    # 2) the arbitrageur never executes at a loss valued at the true price.
    if profit < -_PROFIT_TOL_USD:
        raise ArbInvariantError(
            f"arbitrage executed at a loss ({profit:.6f} USD vs true price {p_star})")

    return ArbResult(
        traded=True,
        zero_for_one=zero_for_one,
        fee_e6=f_e6,
        notional_usd=paid / scale,
        arb_profit_usd=profit,
        lp_fee_usd=out.fee_amount / scale,
        filled=out.fully_filled,
        price_after=pool.price,
        lp_d0=lp_d0,
        lp_d1=lp_d1,
        amount_in=paid,
        amount_out=recv,
        fee_raw=out.fee_amount,
    )


class ConstantFeeEngine:
    """Python reference engine: a flat fee both directions.

    Used for the rest-of-market venue.
    """

    def __init__(self, fee_e6: int):
        self.fee_e6 = int(fee_e6)

    def before_swap(self, block_number: int, current_sqrt_price_x96: int,
                    zero_for_one: bool, commit: bool = True) -> FeeQuote:
        return FeeQuote(fee_e6=self.fee_e6)
