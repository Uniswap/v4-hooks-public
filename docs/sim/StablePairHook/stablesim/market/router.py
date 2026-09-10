"""Best-execution routing across two venues.

A retail order is SPLIT, not sent wholesale. That matters beyond realism: a
split makes a strategy's payoff smooth in its fee, so the optimum is interior
and findable. Wholesale routing would be a step function and would give a
knife-edge best response instead.

Total output is concave in the split: within a block each venue's fee is
FIXED (see env.venue), so the only curvature left is diminishing price
impact. That is what makes the split well-posed. The property fails if fees can
move inside a block, which is one reason the fee is cached.

``split_order`` is the allocation the simulator uses: a closed form,
range-clamped, plus a bounded integer polish.
"""

from __future__ import annotations

from math import isqrt

from ..core import swapmath as sm
from ..core.fixedpoint import ONE_E6, Q96


def total_out(venues, block: int, zero_for_one: bool, amount_in: int, s0: int) -> int:
    """Combined output when venue 0 gets ``s0`` and venue 1 gets the rest."""
    return (venues[0].dry_run_amount_out(block, zero_for_one, s0)
            + venues[1].dry_run_amount_out(block, zero_for_one, amount_in - s0))


def pick_tie(candidates: list[int], amount_in: int) -> int:
    """Choose among equally-good splits without a systematic venue bias.

    Prefer the split closest to an even halving. When ``amount_in`` is odd the
    two best candidates are ``(A-1)//2`` and ``(A+1)//2``, mirror images,
    equally good, and the leftover raw unit has to go somewhere. Route it by
    the parity of ``A >> 1``, which alternates as A advances through odd values.

    Keying on ``A % 2`` does NOT work, and the reasoning is worth keeping: the
    leftover unit only exists when A is odd, so that bit is always 1 and the
    unit always lands on the same venue: a systematic bias with extra steps.
    Sub-bp fees on integer outputs produce plateaus constantly, so always
    preferring one venue on a plateau shorts the other on a measurement that IS
    a difference between venues.

    Note ``abs(2*mirror - A) == abs(2*best - A)`` identically, so mirrorhood is
    the only condition worth testing.
    """
    best = min(candidates, key=lambda s: (abs(2 * s - amount_in), s))
    mirror = amount_in - best
    if mirror != best and mirror in candidates:
        return max(best, mirror) if ((amount_in >> 1) & 1) == 0 else min(best, mirror)
    return best


_Q64 = 1 << 64
_POLISH = 2          # integer window swept around the closed-form candidate

# Any input at least as large as the position's full-range amount delta
# saturates ``compute_swap_step`` and clamps it to the edge. 2**128 clears this
# pool's delta (~1e13 raw units, 2**44) by 2**84, and keeps a U256 port inside
# range too: the widest intermediate is ``amount * sqrtPriceX96`` <= 2**224,
# exactly 2**224 at fee 0, where the fee-adjusted amount equals amount_in
# (2**128) and sqrtPriceX96 at the reference price is exactly 2**96.
_CAP_PROBE = 1 << 128


def _candidate(venues, block: int, zero_for_one: bool, amount_in: int) -> int:
    """Venue 0's share that equalizes fee-adjusted marginal output.

    Integer-only. ``K = sqrt(g_a/g_b) * 2^64`` via exact integer sqrt, because
    the answer is a small difference between numbers of order 2^96 and float
    arithmetic loses it to cancellation.

    Both ``//`` here and ``isqrt`` floor, so K underestimates k and biases x
    toward venue 1 by less than 2^-64, which does not change the integer result.
    ``num // den`` uses Python floor semantics on a possibly negative numerator;
    both floor and truncation land <= 0 there and the clamp in split_order erases
    the difference.
    """
    a, b = venues[0], venues[1]
    pa, pb = a.sim.pool, b.sim.pool
    Sa, Sb = pa.sqrt_price_x96, pb.sqrt_price_x96
    La, Lb = pa.liquidity, pb.liquidity
    ga = ONE_E6 - a.quote(block, zero_for_one)
    gb = ONE_E6 - b.quote(block, zero_for_one)
    # UNREACHABLE GIVEN MAX_FEE_E6 (= 10_000, i.e. 1%), kept deliberately: g is
    # 1e6 - fee, so g <= 0 needs a 100% fee. A porter should neither drop these
    # (they document what the formula does at the degenerate boundary, and the
    # clamp is cheaper than reasoning about it) nor read them as evidence that
    # 100% fees are live: the engine clamps every quote into [0, MAX_FEE_E6].
    if ga <= 0:
        return 0                      # venue 0 takes 100% fee: it can only lose
    if gb <= 0:
        return amount_in
    K = isqrt((ga << 128) // gb)      # ~ sqrt(ga/gb) * 2^64

    if not zero_for_one:
        # S' = S + x*g*Q96/(L*ONE_E6);  condition S_a' = k * S_b'
        M = La * Lb * ONE_E6
        P = ga * Q96 * Lb             # = A_a * M
        Q = gb * Q96 * La             # = B_b * M
        num = K * Sb * M + K * amount_in * Q - _Q64 * Sa * M
        den = _Q64 * P + K * Q
    else:
        # 1/S' = 1/S + x*g/(L*Q96*ONE_E6);  condition S_b' = k * S_a'
        N = La * Lb * Q96 * ONE_E6
        num = K * N * Sa + K * amount_in * gb * La * Sa * Sb - _Q64 * N * Sb
        den = Sa * Sb * (_Q64 * ga * Lb + K * gb * La)
    if den == 0:
        # Also unreachable at legal fees: den is a sum of strictly positive
        # products once ga, gb > 0 and L, S > 0. Kept for the same reason.
        return amount_in // 2
    return num // den


def _edge_capacity(v, block: int, zero_for_one: bool) -> int:
    """Gross input (fee included) that takes ``v`` EXACTLY to its range edge.

    Past that point the single position is exhausted: every further raw unit
    buys zero output, so no optimum ever hands a venue more than this. Computed
    by saturating ``compute_swap_step``, the same function execution uses, so the
    capacity inherits the identical rounding: on a clamped step the function
    returns the edge ``amount_in_used`` plus the fee charged on it, and their sum
    is what ``Venue.execute`` will consume. One swap-math evaluation per venue per
    order; the fee is the cached per-block quote.
    """
    pool = v.sim.pool
    target = pool.sqrt_lower_x96 if zero_for_one else pool.sqrt_upper_x96
    sqrt_next, used, _, fee_amt = sm.compute_swap_step(
        pool.sqrt_price_x96, target, pool.liquidity, _CAP_PROBE,
        v.quote(block, zero_for_one), zero_for_one)
    # If _CAP_PROBE were ever too small to clamp, compute_swap_step would
    # return an unclamped step and this would silently report the probe
    # amount itself as "capacity": reverting the router to range-blind
    # behaviour with no error. Make that failure loud instead of silent.
    assert sqrt_next == target, (
        f"_CAP_PROBE={_CAP_PROBE} did not reach the range edge "
        f"(sqrt_next={sqrt_next}, target={target}); capacity is unreliable"
    )
    return used + fee_amt


def split_order(venues, block: int, zero_for_one: bool, amount_in: int,
                gas_raw: int = 0) -> list[int]:
    """Default allocation: closed form, range-clamped, plus a bounded polish.

    ``gas_raw`` (default 0) is a fixed cost per venue LEG in raw output-token
    units: the all-in value of an allocation is its total output minus the gas
    of the venues actually used. An int applies to both venues; a 2-sequence
    gives per-venue costs, which is how an asymmetric routing cost is modelled:
    the rest of the market is the default route, so single-homing there can be
    cheaper than touching a new pool. The single-home corners are already in the
    scored window (they are the range-clamp corners lo/hi whenever a venue can
    absorb the whole order), so gas costs no extra swap-math probes: it only
    changes which scored candidate wins. With a per-leg cost, small orders
    single-home and only large orders pay for two legs.

    The polish absorbs the final floor and nothing more: the sqrt-price update is
    affine but the fills are rounded, so the continuous optimum lands within one
    unit of the integer one.

    Range awareness is required. _candidate solves the affine sqrt-price update,
    which only holds while BOTH venues stay inside their positions; the polish
    window cannot reach an edge-limited optimum, which sits millions of raw units
    away. Left unclamped it would route more to a venue than its range can absorb
    and starve the other. The clamp costs one extra swap-math evaluation per
    venue and no extra window entries.

    _POLISH stays at 2. The objective carries near-tied local optima millions of
    raw units apart that differ by about one unit in value, so no bounded window
    bridges them, and widening it only adds swap-math calls.
    """
    if not venues:
        return []
    if len(venues) == 1:
        return [amount_in]
    if amount_in <= 0:
        return [0] * len(venues)

    # The feasible band, and the reason the corners below are NOT 0 and
    # amount_in. Two hard bounds, one per venue:
    #     s <= cap_a                 (never overfill venue 0)
    #     amount_in - s <= cap_b     (never overfill venue 1)
    # Outside the band the objective is monotone toward it (a saturated venue's
    # output is constant, the other's is strictly increasing in what it gets), so
    # 0 and amount_in are WEAKLY DOMINATED by these two edge-fill points and drop
    # out. That keeps the window at the same size, a 7-entry set, 14 dry-runs,
    # instead of growing it, which the O(1) call-count bounds care about.
    #
    # When amount_in exceeds cap_a + cap_b the two bounds CROSS. Both venues then
    # fill to their edges for every split in between and the objective is exactly
    # flat across it, so sorted() reads the crossed pair as that tie interval
    # rather than as an empty one, and the polish + pick_tie centre inside it.
    cap_a = _edge_capacity(venues[0], block, zero_for_one)
    cap_b = _edge_capacity(venues[1], block, zero_for_one)
    lo, hi = sorted((max(0, amount_in - cap_b), min(amount_in, cap_a)))

    x0 = min(max(_candidate(venues, block, zero_for_one, amount_in), lo), hi)
    window = {min(max(x0 + d, lo), hi) for d in range(-_POLISH, _POLISH + 1)}
    window |= {lo, hi}                # edge-aware corners; see above

    # Score each candidate EXACTLY ONCE. Evaluating inside max() and again inside
    # the tied-filter doubles the venue probes: 7 candidates x 2 passes x 2 venues
    # is 28 dry-runs, over the 24-call O(1) budget the tests enforce.
    scored = {s: total_out(venues, block, zero_for_one, amount_in, s) for s in window}
    g0, g1 = (gas_raw, gas_raw) if isinstance(gas_raw, int) else gas_raw
    if g0 > 0 or g1 > 0:
        # Net value = output minus the gas of each leg used. A leg is "used"
        # when it receives a positive share; the zero-gas path is untouched so
        # gas_raw=0 reproduces the pre-gas selection bit for bit.
        scored = {s: v - g0 * (s > 0) - g1 * (s < amount_in)
                  for s, v in scored.items()}
    best_val = max(scored.values())
    best = pick_tie(sorted(s for s, v in scored.items() if v == best_val), amount_in)
    return [best, amount_in - best]
