"""One competing pool: a Simulator plus the per-block LP books.

The fee is quoted ONCE per block per direction, EAGERLY at block start, from the
block-start pool state AND the block-start strategy state; every fill in that
block, retail legs and the arb, pays the cached value. That is not a
performance hack: it is what the on-chain hook actually does (it caches its fee
and direction rule at the first swap of each block), it is what makes the
router's concavity assumption true, and it removes any gain from slicing one
trade into many. Quoting both directions up front is what makes "from
block-start state" true for a STATEFUL strategy too: see CachedQuoteEngine.

The cache itself lives on :class:`CachedQuoteEngine`, a wrapper around the fee
engine, rather than on ``Venue``. ``arb_step`` (market/arbitrageur.py) and
``Simulator.swap`` (core/pool.py) both call ``sim.engine.before_swap`` directly,
and neither goes through ``Venue.quote``, so a cache living on ``Venue`` would
be bypassed by the arb entirely: it would quote at the post-retail price
instead of block-start state, the real call count would double (arb peek +
arb execute, on top of retail), and ``Venue.quote_calls`` would report half the
true cost. Wrapping the engine instead means every path in (arb peek, arb
execute, retail quote, retail execute) is served from the same one call per
block per direction.

``dry_run_amount_out`` is the router's only window onto a venue. It reads the
cached fee and runs the pure swap math, so the router can probe a venue
hundreds of times without ever reaching the strategy.
"""

from __future__ import annotations

from ..core import swapmath as sm
from ..core.fixedpoint import Q96
from ..core.pool import ConcentratedPool, FeeQuote, Simulator, SwapOutcome, price_to_sqrt_x96
from ..market.price_process import REFERENCE_PRICE
from . import config as C


def moves_toward_peg(sqrt_price_x96: int, zero_for_one: bool) -> bool:
    """Would a fill in this direction move the pool's price toward 1:1?

    DIAGNOSTIC ONLY: nothing in the simulation branches on this. It exists so a
    study can split executed volume into toward-peg and away-from-peg legs, which
    is what distinguishes "a split fee captures more flow" from "a split fee makes
    the taxed side larger". Those two explanations predict the same total volume
    and are otherwise indistinguishable.

    `zero_for_one` sells token0 and pushes price down, so a fill moves toward the
    peg when the pool is above it and the fill pushes down, or below and pushes
    up. Exactly at 1:1 both directions count as toward; it is a measure-zero case
    and the choice only affects a diagnostic.
    """
    if zero_for_one:
        return sqrt_price_x96 >= Q96
    return sqrt_price_x96 <= Q96


class CachedQuoteEngine:
    """Quotes BOTH directions once, eagerly, at block-start state, then serves
    every later call in the block from that cache.

    The cache belongs here rather than on Venue because arb_step and
    Simulator.swap both call ``sim.engine.before_swap`` directly. A cache on
    Venue's own API would be bypassed by both, letting the arb quote at a
    post-retail price and doubling the real call count while Venue's counter
    still reported compliance.

    Eager, not lazy, and that is a correctness property. Latching the
    block-start PRICE but calling the inner engine lazily at the first touch of
    each direction is wrong for a stateful strategy: ``afterSwap`` fires on
    every retail leg between those two first touches, so the second direction's
    fee would be computed against post-retail storage. That breaks the
    interface's guarantee that ``beforeSwap`` is called once per block per
    direction from block-start state, and it opens a within-block manipulation
    channel: trade direction A early to move the fee direction B pays later in
    the same block. Eager quoting costs the two staticcalls per block per venue
    the design already budgets, so the guarantee is free.

    ``current_sqrt_price_x96`` is ignored by ``before_swap``: the latched
    block-start price is used instead. It is not dead: on the first touch of a
    new block it is what gets latched, which is how a caller that never calls
    ``start_block`` still behaves correctly.

    ``commit`` is not forwarded. Both inner calls happen inside ``start_block``,
    before any caller with a commit intent exists, so there is no value to
    forward, and forwarding it would make the block's fee depend on whether the
    block's first toucher was peeking or executing. ``commit`` is inert anyway
    for the strategies that matter (``beforeSwap`` is a view invoked by
    staticcall), and pinning it to False is
    what makes "the fee peeked is the fee charged" hold by construction.
    """

    # Quoting order. Unobservable in any result: beforeSwap is a view, so
    # neither call can affect the other or anything else. Fixed anyway so the
    # call sequence a port emits is deterministic and reviewable.
    _DIRECTIONS = (False, True)

    def __init__(self, inner):
        self.inner = inner
        self._block: int | None = None
        self._start_sqrt: int | None = None
        self._cache: dict[bool, int] = {}
        self.quote_calls = 0

    def start_block(self, block: int, sqrt_price_x96: int) -> None:
        """Latch the block-start price and quote both directions against it.

        Idempotent within a block. Block numbers must be monotonic
        non-decreasing: going backwards is an error, since the block-start
        price for the earlier block is no longer recoverable.
        """
        if block == self._block:
            return
        if self._block is not None and block < self._block:
            raise RuntimeError(
                f"Cannot revert to block {block}: already advanced to block {self._block}. "
                f"Block-start price for block {block} is no longer recoverable."
            )
        self._block = block
        self._start_sqrt = sqrt_price_x96
        self._cache = {}
        for zero_for_one in self._DIRECTIONS:
            self.quote_calls += 1
            self._cache[zero_for_one] = self.inner.before_swap(
                block, sqrt_price_x96, zero_for_one, commit=False).fee_e6

    def before_swap(self, block_number: int, current_sqrt_price_x96: int,
                    zero_for_one: bool, commit: bool = True) -> FeeQuote:
        if self._block != block_number:
            # First touch of a new block by any caller latches its start price
            # and quotes both directions there.
            self.start_block(block_number, current_sqrt_price_x96)
        return FeeQuote(fee_e6=self._cache[zero_for_one])

    # --- lifecycle passes straight through --------------------------------
    def after_initialize(self, sqrt_price_x96: int, liquidity: int) -> None:
        if hasattr(self.inner, "after_initialize"):
            self.inner.after_initialize(sqrt_price_x96, liquidity)

    def notify_swap(self, **kw) -> None:
        if hasattr(self.inner, "notify_swap"):
            self.inner.notify_swap(**kw)


class Venue:
    def __init__(self, name: str, sim: Simulator):
        self.name = name
        self.sim = sim
        # LP books: signed raw inventory deltas, summed, marked once at the
        # final price.
        self.sum_d0 = 0
        self.sum_d1 = 0
        self.volume = 0.0
        # Routed legs only, in RAW token units; the arb is booked separately by
        # two_venue._book_arb. Exact ints on purpose: it lets two_venue build
        # volume_share as an integer ratio instead of a float numerator over an
        # exactly-divided int denominator, which is not bounded by 1.
        self.retail_raw = 0
        # Diagnostic split of ALL executed notional (retail legs and arb legs
        # alike) by whether the fill moved price toward or away from 1:1. Exact
        # ints. Nothing in the simulation branches on these: see
        # moves_toward_peg at module level for what they are for.
        self.toward_raw = 0
        self.away_raw = 0
        self.lp_fee = 0.0
        self.trades = 0

    # --- the cache (delegated to sim.engine, a CachedQuoteEngine) --------
    def quote(self, block: int, zero_for_one: bool) -> int:
        """The fee for ``block`` in ``zero_for_one``, computed at most once.

        Delegates to the engine wrapper so every path into the strategy,
        this call included, shares the same one-quote-per-block-per-direction
        cache. See ``CachedQuoteEngine`` above for why the cache cannot live
        here.
        """
        return self.sim.engine.before_swap(
            block, self.sim.pool.sqrt_price_x96, zero_for_one, commit=False).fee_e6

    def book_direction(self, sqrt_before_x96: int, zero_for_one: bool,
                       consumed: int) -> None:
        """Record executed notional against the toward/away diagnostic counters.

        Called for retail fills by `execute` and for arb fills by
        `two_venue._book_arb`, which must pass the PRE-swap price: the post-swap
        price can sit on the far side of the peg and would misclassify the fill.
        """
        if consumed <= 0:
            return
        if moves_toward_peg(sqrt_before_x96, zero_for_one):
            self.toward_raw += consumed
        else:
            self.away_raw += consumed

    def start_block(self, block: int) -> None:
        """Latch block-start state and take both of the block's quotes there.

        Idempotent within a block. Calling it explicitly at the top of each block
        (as two_venue does) is what guarantees BOTH directions are quoted before
        anything in the block trades, so neither the pool price nor the
        strategy's own storage can have moved between the two quotes.
        """
        self.sim.engine.start_block(block, self.sim.pool.sqrt_price_x96)

    @property
    def quote_calls(self) -> int:
        return self.sim.engine.quote_calls

    # --- the router's view -----------------------------------------------
    def dry_run_amount_out(self, block: int, zero_for_one: bool, amount_in: int) -> int:
        """Output for ``amount_in``, without touching the pool or the strategy."""
        if amount_in <= 0:
            return 0
        pool = self.sim.pool
        fee = self.quote(block, zero_for_one)
        target = pool.sqrt_lower_x96 if zero_for_one else pool.sqrt_upper_x96
        _, _, out, _ = sm.compute_swap_step(
            pool.sqrt_price_x96, target, pool.liquidity, amount_in, fee, zero_for_one)
        return out

    # --- execution -------------------------------------------------------
    def execute(self, block: int, zero_for_one: bool, amount_in: int) -> SwapOutcome | None:
        """Fill ``amount_in`` at the cached fee and book the LP's side."""
        if amount_in <= 0:
            return None
        fee = self.quote(block, zero_for_one)
        pool = self.sim.pool
        target = pool.sqrt_lower_x96 if zero_for_one else pool.sqrt_upper_x96
        sqrt_before = pool.sqrt_price_x96
        sqrt_after, used, out, fee_amt = sm.compute_swap_step(
            sqrt_before, target, pool.liquidity, amount_in, fee, zero_for_one)
        pool.sqrt_price_x96 = sqrt_after
        consumed = used + fee_amt
        if consumed <= 0:
            return None
        if zero_for_one:                 # trader pays token0, LP receives it
            self.sum_d0 += consumed
            self.sum_d1 -= out
        else:
            self.sum_d0 -= out
            self.sum_d1 += consumed
        self.volume += consumed / C.SCALE
        # execute() is reached ONLY by routed retail (the arb goes through
        # arb_step and is booked by two_venue._book_arb), so this cleanly
        # isolates retail notional, which the comparability invariant asserts on.
        self.retail_raw += consumed
        self.book_direction(sqrt_before, zero_for_one, consumed)
        self.lp_fee += fee_amt / C.SCALE
        self.trades += 1
        return SwapOutcome(
            fee=FeeQuote(fee_e6=fee),
            amount_in_consumed=consumed,
            amount_in_unfilled=amount_in - consumed,
            amount_out=out,
            fee_amount=fee_amt,
            sqrt_price_before_x96=sqrt_before,
            sqrt_price_after_x96=sqrt_after,
            fully_filled=consumed >= amount_in,
        )


def build_venue(name: str, engine, p0: float, *, tvl_usd: float | None = None,
                half_width_bps: float | None = None) -> Venue:
    """A venue whose pool matches the scored pool exactly, priced at ``p0``.

    Identical construction for both venues by default: same TVL input, same
    range, so the same L. Fee is the only thing that differs between them.
    ``tvl_usd`` overrides the depth for one venue, which is what models a deep
    "rest of the market" instead of an equal-sized rival. It defaults to
    config.TVL_USD.

    The engine is wrapped in ``CachedQuoteEngine`` here, so every venue built
    through this constructor, the only supported way to build one, gets
    the one-quote-per-block-per-direction cache automatically.
    """
    tvl = C.TVL_USD if tvl_usd is None else float(tvl_usd)
    # Width and TVL only matter through their RATIO (local liquidity ~ TVL/width)
    # until a range edge binds. The published runs use ±20bp, the tightest width
    # validated for this pair's process (see methodology.md).
    hw = C.POOL_HALF_WIDTH_BPS if half_width_bps is None else float(half_width_bps)
    pool = ConcentratedPool.from_value(REFERENCE_PRICE, hw, tvl)
    sqrt0 = price_to_sqrt_x96(p0)
    pool.sqrt_price_x96 = min(max(sqrt0, pool.sqrt_lower_x96), pool.sqrt_upper_x96)
    return Venue(name, Simulator(pool, CachedQuoteEngine(engine)))
