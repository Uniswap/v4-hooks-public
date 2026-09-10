"""Exact fixed-point primitives, ported wei-for-wei from the on-chain math.

Everything here mirrors the integer arithmetic the Uniswap v4 contracts rely on
so that amounts computed in Python match the EVM to the last unit:

* ``mul_div`` family: Uniswap ``FullMath`` semantics (512-bit exact;
  trivial with Python big ints).
* ``sdiv``: EVM signed division (truncates toward zero).
* fixed-point scales: Q96 / Q48 / Q24 and the E6 fee precision (pips),
  plus WAD and the TickMath sqrt-price limits.

EVM signedness notes:
* Solidity ``sar`` (arithmetic shift right) == Python ``>>`` for ints (both floor
  toward -inf), so we use ``>>`` directly.
* Solidity ``sdiv`` / ``/`` truncate toward zero, which Python ``//`` does NOT do
  for negatives: use :func:`sdiv` where the dividend may be negative.
"""

from __future__ import annotations

# --- fixed-point scales -----------------------------------------------------
Q96 = 1 << 96
Q48 = 1 << 48
Q24 = 1 << 24

ONE_E6 = 1_000_000          # pips precision (1e6 == 100%)
ONE_E12 = 1_000_000_000_000  # scaled precision (1e12 == 100%); currently unused

# Uniswap TickMath sqrt-price limits.
MIN_SQRT_PRICE = 4295128739
MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342

WAD = 10**18


def sdiv(a: int, b: int) -> int:
    """EVM signed division: truncates toward zero (unlike Python ``//``)."""
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


# --- FullMath -----------------------------------------------------------------
def mul_div(a: int, b: int, denominator: int) -> int:
    """floor(a * b / denominator), full precision (FullMath.mulDiv)."""
    return (a * b) // denominator


def mul_div_rounding_up(a: int, b: int, denominator: int) -> int:
    """ceil(a * b / denominator) (FullMath.mulDivRoundingUp)."""
    product = a * b
    q, r = divmod(product, denominator)
    return q + (1 if r else 0)


def div_rounding_up(x: int, y: int) -> int:
    """ceil(x / y) for non-negative operands (UnsafeMath.divRoundingUp)."""
    q, r = divmod(x, y)
    return q + (1 if r else 0)
