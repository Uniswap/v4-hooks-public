"""One path with two competing pools and routed retail flow.

Per block, in this order:

    1. QUOTE: each venue's fee, per direction, from block-start state, cached
    2. RETAIL: Poisson orders, each split across both venues by best execution
    3. ARB: arb_step against each venue independently

Arb goes LAST, and that is a correctness decision rather than a stylistic one.
Under arb-first every block would END displaced by retail, so the block-start
state that sets the NEXT block's cached fee would be whatever the last retail
order left behind: letting anyone trading late in block n choose the fee
everyone pays in block n+1. Arb-last leaves every block ending at (within a fee
width of) p*, so the quote state is exogenous. It also matches what a rational
monopolist arb would choose: waiting gives it a max(0, .) payoff on retail's
mean-zero displacement.

Two RNG streams. The price path uses random.Random(seed), so the frozen draw
order is untouched; retail uses its own
random.Random(seed + RETAIL_SEED_OFFSET). Python's gauss cache is per-instance,
so the two cannot interleave.
"""

from __future__ import annotations

import random
from dataclasses import dataclass

from ..market.arbitrageur import ConstantFeeEngine, arb_step
from ..market.price_process import BLOCK_SECONDS, stochastic_vol
from ..market.router import split_order
from . import config as C
from ..core.pool import price_to_sqrt_x96
from .venue import Venue, build_venue


@dataclass
class TwoVenueResult:
    """Per-path result of a two-venue run: the scored pool's pnl, fees and
    volume, the rival's pnl, retail arrival and execution counts, and two
    diagnostics (``vol_mean``, ``track_err_bp``).
    """
    vol_mean: float
    pnl: float                  # scored pool: gross terminal markout, token1
    volume: float
    lp_fee: float
    trades: int
    track_err_bp: float         # scored pool, per-block mean |pool - market| in bp
    volume_share: float         # scored pool's share of EXECUTED routed notional
    rival_pnl: float
    rival_volume: float
    # Retail notional that arrived vs what executed. A leg that saturates its
    # venue's range edge drops its remainder, so the two can differ.
    retail_arrived: float
    retail_executed: float
    # Diagnostic: scored pool's executed notional split by whether the fill moved
    # price toward or away from 1:1, across BOTH retail and arb legs. Nothing
    # branches on it. It exists to separate "a
    # split fee captures more flow" from "a split fee makes the taxed side
    # larger": two explanations that predict identical total volume.
    toward_volume: float
    away_volume: float


def _book_arb(v: Venue, r, block: int, notify: bool, sqrt_before_x96: int) -> None:
    """Fold an ArbResult into a venue's books, and notify the strategy.

    The amounts forwarded here are the executed legs from ArbResult.

    `sqrt_before_x96` is the venue's price BEFORE the arb fill, captured by the
    caller. It is only used for the toward/away diagnostic, and it has to be the
    pre-swap price: the arb can cross the peg in one fill, so the post-swap price
    would classify such a leg backwards.
    """
    v.sum_d0 += r.lp_d0
    v.sum_d1 += r.lp_d1
    v.volume += r.notional_usd
    v.lp_fee += r.lp_fee_usd
    v.book_direction(sqrt_before_x96, r.zero_for_one, r.amount_in)
    v.trades += 1
    if notify and hasattr(v.sim.engine, "notify_swap"):
        v.sim.engine.notify_swap(
            zero_for_one=r.zero_for_one, block_number=block,
            amount_in=r.amount_in, amount_out=r.amount_out,
            fee_amount=r.fee_raw, sqrt_price_x96=v.sim.pool.sqrt_price_x96,
        )


def run_two_venue_path(engine, cfg: C.PathConfig, *, notify: bool = False,
                       rival_fee_e6: int | None = None,
                       retail_orders,
                       rival_tvl_usd: float | None = None,
                       rival_tracks_fair: bool = False,
                       half_width_bps: float | None = None,
                       router_gas_raw: int | tuple[int, int] = 0,
                       price_path=None,
                       scored_tvl_usd: float | None = None,
                       scored_half_width_bps: float | None = None,
                       integration_coverage: float = 1.0) -> TwoVenueResult:
    """Run one path with the scored pool against the rest-of-market venue.

    ``retail_orders``: a callable ``(rng) -> list[RetailOrder]`` producing the
    block's retail orders; the runner passes the empirical size generator.

    ``integration_coverage``: the probability that a retail order's router quotes
    the scored pool at all. Integration is a binary per-router state, not a
    marginal cost: an order whose router has not integrated routes entirely to
    the rival, whatever the prices. Draws come from a dedicated RNG stream, so the
    retail stream is untouched and identical seeds give identical integration
    outcomes across configurations. 1.0 quotes the scored pool on every order.

    ``rival_tvl_usd`` and ``rival_tracks_fair``: turn the rival from an
    equal-sized competing pool into a deep rest of the market, re-synced to the
    prevailing fair price at the top of every block and never arbitraged, so it
    is always correctly priced when retail arrives. An equal-sized rival would
    mean our pool contests roughly half of all flow by construction. With a deep
    rest of market the pool's share of flow is an output of routing, and it wins
    the small orders first, where a fee edge bites.
    """
    rival_fee_e6 = C.RIVAL_FEE_E6 if rival_fee_e6 is None else rival_fee_e6
    rival_tvl = C.TVL_USD if rival_tvl_usd is None else float(rival_tvl_usd)

    price_rng = random.Random(cfg.seed)
    if price_path is None:
        path, vol_mults = stochastic_vol().simulate(cfg.blocks, BLOCK_SECONDS, price_rng)
    else:
        # Optional: a pre-built (path, vol_mults) pair replaces the default
        # process. The default branch and its RNG draw order are unchanged.
        path, vol_mults = price_path
        assert len(path) == cfg.blocks + 1, "price_path length must be blocks+1"
    retail_rng = random.Random(cfg.seed + C.RETAIL_SEED_OFFSET)
    integration_rng = (random.Random(cfg.seed + C.INTEGRATION_SEED_OFFSET)
                       if integration_coverage < 1.0 else None)

    scored = build_venue("scored", engine, path[0], tvl_usd=scored_tvl_usd,
                         half_width_bps=(half_width_bps if scored_half_width_bps is None
                                         else scored_half_width_bps))
    rival = build_venue("rival", ConstantFeeEngine(rival_fee_e6), path[0],
                        tvl_usd=rival_tvl, half_width_bps=half_width_bps)
    venues = [scored, rival]

    if notify and hasattr(engine, "after_initialize"):
        engine.after_initialize(scored.sim.pool.sqrt_price_x96, scored.sim.pool.liquidity)

    abs_err = 0.0
    arrived_raw = 0          # exact int: notional the retail process generated
    for n in range(1, cfg.blocks + 1):
        if rival_tracks_fair:
            # The rest of the market is efficient: correctly priced whenever retail
            # arrives, and never a source of arbitrage. Re-sync BEFORE start_block
            # so the quote cache latches the synced price, not the stale one.
            rp = rival.sim.pool
            rp.sqrt_price_x96 = min(max(price_to_sqrt_x96(path[n]),
                                        rp.sqrt_lower_x96), rp.sqrt_upper_x96)
        for v in venues:
            v.start_block(n)

        # --- routed retail ------------------------------------------------
        orders = retail_orders(retail_rng)
        for order in orders:
            arrived_raw += order.amount_in
            if integration_rng is not None and integration_rng.random() >= integration_coverage:
                # this order's router has not integrated the scored pool: the
                # whole order goes to the rival, whatever the prices
                splits = [0, order.amount_in]
            else:
                splits = split_order(venues, n, order.zero_for_one, order.amount_in,
                                     gas_raw=router_gas_raw)
            for v, s in zip(venues, splits):
                if s <= 0:
                    continue
                # ``out.amount_in_unfilled`` is DELIBERATELY IGNORED: a leg that
                # saturates its venue's range edge drops its remainder rather
                # than re-routing it. The remainder is unfillable at any price
                # (the single position is exhausted past the edge), and
                # re-routing would change the router's objective, its cost bound
                # and the smoothness argument the design rests on. Measured by
                # retail_arrived vs retail_executed below.
                out = v.execute(n, order.zero_for_one, s)
                if out is not None and notify and hasattr(v.sim.engine, "notify_swap"):
                    v.sim.engine.notify_swap(
                        zero_for_one=order.zero_for_one, block_number=n,
                        amount_in=out.amount_in_consumed, amount_out=out.amount_out,
                        fee_amount=out.fee_amount,
                        sqrt_price_x96=v.sim.pool.sqrt_price_x96,
                    )

        # --- arb, each venue independently --------------------------------
        p_star = path[n]
        arb_venues = [scored] if rival_tracks_fair else venues
        for v in arb_venues:
            pre_arb_sqrt = v.sim.pool.sqrt_price_x96
            r = arb_step(v.sim, n, p_star)
            if r.traded:
                _book_arb(v, r, n, notify, pre_arb_sqrt)
        abs_err += abs(scored.sim.pool.price - p_star) * 1e4

    p_end = path[-1]
    # Shares from EXACT INTS on both sides. A float numerator over an
    # exactly-divided int denominator is not bounded by 1.
    exec_raw = scored.retail_raw + rival.retail_raw
    return TwoVenueResult(
        vol_mean=sum(vol_mults) / len(vol_mults),
        pnl=(scored.sum_d0 * p_end + scored.sum_d1) / C.SCALE,
        volume=scored.volume,
        lp_fee=scored.lp_fee,
        trades=scored.trades,
        track_err_bp=abs_err / cfg.blocks,
        volume_share=(scored.retail_raw / exec_raw) if exec_raw > 0 else 0.0,
        rival_pnl=(rival.sum_d0 * p_end + rival.sum_d1) / C.SCALE,
        rival_volume=rival.volume,
        retail_arrived=arrived_raw / C.SCALE,
        retail_executed=exec_raw / C.SCALE,
        toward_volume=scored.toward_raw / C.SCALE,
        away_volume=scored.away_raw / C.SCALE,
    )
