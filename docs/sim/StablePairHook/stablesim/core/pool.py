"""A single-position concentrated-liquidity v4 pool plus a swap simulator that
drives it with the fee quoted by the design under test.

The scored pool is one concentrated position: $10M TVL over +-2% around 1:1
(``config.TVL_USD``, ``config.POOL_HALF_WIDTH_BPS``). We model exactly that:
constant liquidity ``L`` inside [sqrt_lower, sqrt_upper] and none outside. Swaps
that would push price past a range edge clamp to the edge and only partially
fill (the position is exhausted).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from . import swapmath
from .fixedpoint import Q96


# --- price <-> sqrtPriceX96 helpers ------------------------------------------
def price_to_sqrt_x96(price: float) -> int:
    """price (token1/token0, equal decimals) -> sqrtPriceX96."""
    return int(math.isqrt(int(price * (1 << 192))))


def sqrt_x96_to_price(sqrt_px96: int) -> float:
    return (sqrt_px96 / Q96) ** 2


def bps_offset_sqrt(reference_sqrt_x96: int, bps: float) -> int:
    """sqrt price ``bps`` basis points away from a reference sqrt price."""
    return int(reference_sqrt_x96 * math.sqrt(1 + bps / 10_000))


@dataclass(frozen=True)
class FeeQuote:
    """A quoted fee for one incoming swap, in e6 pips (100 = 1 bp)."""
    fee_e6: int


@dataclass
class SwapOutcome:
    fee: "FeeQuote"
    amount_in_consumed: int
    amount_in_unfilled: int
    amount_out: int
    fee_amount: int
    sqrt_price_before_x96: int
    sqrt_price_after_x96: int
    fully_filled: bool

    @property
    def price_after(self) -> float:
        return sqrt_x96_to_price(self.sqrt_price_after_x96)


class ConcentratedPool:
    """Single position [sqrt_lower, sqrt_upper] with constant liquidity ``L``."""

    def __init__(self, sqrt_price_x96: int, liquidity: int, sqrt_lower_x96: int, sqrt_upper_x96: int):
        if not (sqrt_lower_x96 <= sqrt_price_x96 <= sqrt_upper_x96):
            raise ValueError("initial price must lie within the position range")
        self.sqrt_price_x96 = sqrt_price_x96
        self.liquidity = liquidity
        self.sqrt_lower_x96 = sqrt_lower_x96
        self.sqrt_upper_x96 = sqrt_upper_x96

    @classmethod
    def from_ticks(
        cls, tick_lower: int, tick_upper: int, liquidity: int, sqrt_price_x96: int | None = None
    ) -> "ConcentratedPool":
        """Build a position from exact tick bounds + liquidity (e.g. on-chain values)."""
        from .ticklib import get_sqrt_ratio_at_tick

        sqrt_lo = get_sqrt_ratio_at_tick(tick_lower)
        sqrt_hi = get_sqrt_ratio_at_tick(tick_upper)
        sp = sqrt_price_x96 if sqrt_price_x96 is not None else price_to_sqrt_x96(1.0)
        return cls(sp, liquidity, sqrt_lo, sqrt_hi)

    @classmethod
    def from_value(
        cls,
        center_price: float,
        half_width_bps: float,
        total_value: float,
        *,
        token_price_usd: float = 1.0,
        decimals: int = 6,
    ) -> "ConcentratedPool":
        """Build a position worth ~``total_value`` USD over +-``half_width_bps``.

        Assumes a stable/stable pool starting at ``center_price`` with both tokens
        ~``token_price_usd``. Splits value across the two tokens and solves for L.
        """
        scale = 10**decimals
        sqrt_p = price_to_sqrt_x96(center_price)
        sqrt_lo = bps_offset_sqrt(sqrt_p, -half_width_bps)
        sqrt_hi = bps_offset_sqrt(sqrt_p, +half_width_bps)
        # Split USD value evenly across the two sides, convert to raw token units.
        half = (total_value / 2) / token_price_usd
        amount0 = int(half * scale)
        amount1 = int(half * scale)
        liquidity = swapmath.get_liquidity_for_amounts(sqrt_p, sqrt_lo, sqrt_hi, amount0, amount1)
        return cls(sqrt_p, liquidity, sqrt_lo, sqrt_hi)

    @property
    def price(self) -> float:
        return sqrt_x96_to_price(self.sqrt_price_x96)

    def amounts(self, decimals: int = 6) -> tuple[float, float]:
        a0, a1 = swapmath.get_amounts_for_liquidity(
            self.sqrt_price_x96, self.sqrt_lower_x96, self.sqrt_upper_x96, self.liquidity
        )
        return a0 / 10**decimals, a1 / 10**decimals

    def swap(self, zero_for_one: bool, amount_in: int, fee_pips: int):
        """Execute an exact-input swap against the single position."""
        target = self.sqrt_lower_x96 if zero_for_one else self.sqrt_upper_x96
        sqrt_next, used, out, fee_amt = swapmath.compute_swap_step(
            self.sqrt_price_x96, target, self.liquidity, amount_in, fee_pips, zero_for_one
        )
        self.sqrt_price_x96 = sqrt_next
        return sqrt_next, used, out, fee_amt


class Simulator:
    """Couples a :class:`ConcentratedPool` with a fee engine.

    The engine must expose ``before_swap(block_number, sqrt_price_x96,
    zero_for_one, commit=True) -> FeeQuote``.
    """

    def __init__(self, pool: ConcentratedPool, engine):
        self.pool = pool
        self.engine = engine

    def swap(self, block_number: int, zero_for_one: bool, amount_in: int) -> SwapOutcome:
        sqrt_before = self.pool.sqrt_price_x96
        fee = self.engine.before_swap(block_number, sqrt_before, zero_for_one)
        sqrt_after, used, out, fee_amt = self.pool.swap(zero_for_one, amount_in, fee.fee_e6)
        return SwapOutcome(
            fee=fee,
            amount_in_consumed=used + fee_amt,
            amount_in_unfilled=amount_in - (used + fee_amt),
            amount_out=out,
            fee_amount=fee_amt,
            sqrt_price_before_x96=sqrt_before,
            sqrt_price_after_x96=sqrt_after,
            fully_filled=(used + fee_amt) >= amount_in,
        )
