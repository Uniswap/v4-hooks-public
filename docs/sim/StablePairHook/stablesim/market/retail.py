"""Retail order type and the Poisson arrival draw.

Direction is a fair coin that never looks at price, so retail carries no adverse
selection: it displaces the pool, the arb reverts the displacement, and the LP
round-trips it while keeping both fees.

Draw order is a portability contract: per block, the Poisson count, then per
order the direction draw followed by the size draw.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass


@dataclass(frozen=True)
class RetailOrder:
    zero_for_one: bool
    amount_in: int                   # raw 6-decimal units


def _poisson(lam: float, rng: random.Random) -> int:
    """Knuth's product algorithm.

    Consumes no randomness when ``lam <= 0``. A different Poisson sampler would
    consume a different number of uniforms and change every downstream draw.
    """
    if lam <= 0.0:
        return 0
    limit = math.exp(-lam)
    k = 0
    prod = rng.random()
    while prod > limit:
        k += 1
        prod *= rng.random()
    return k
