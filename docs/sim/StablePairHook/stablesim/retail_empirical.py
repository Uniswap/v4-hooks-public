"""Retail order sizes drawn from an empirical inverse-CDF.

Sampling the quantile table directly makes no distributional assumption: the
simulated size distribution is the observed one, up to interpolation between
percentiles. A fitted curve would keep two moments and guess the tail, which is
exactly where fitted curves are least trustworthy.

Draw order is a hard contract, identical to the parametric generator so the two
are interchangeable from the RNG's point of view: Poisson count first (Knuth
product, consuming nothing when the rate is non-positive), then per order a
direction draw followed by a size draw. Changing it desynchronizes every seeded
stream.
"""

from __future__ import annotations

import csv
from pathlib import Path

from stablesim.market.retail import RetailOrder, _poisson

_SCALE = 10**6


def load_quantiles(path: str | Path) -> tuple[list[float], list[float]]:
    """Read a `pct,size_usd` table into parallel ascending lists."""
    pcts: list[float] = []
    vals: list[float] = []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            pcts.append(float(row["pct"]))
            vals.append(float(row["size_usd"]))
    if pcts != sorted(pcts):
        raise ValueError(f"{path}: pct column must be ascending")
    return pcts, vals


def _interp(x: float, xs: list[float], ys: list[float]) -> float:
    """Linear interpolation, clamped at both ends. Stdlib only, no numpy."""
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    lo, hi = 0, len(xs) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if xs[mid] <= x:
            lo = mid
        else:
            hi = mid
    span = xs[hi] - xs[lo]
    if span <= 0:
        return ys[lo]
    w = (x - xs[lo]) / span
    return ys[lo] * (1.0 - w) + ys[hi] * w


class QuantileRetail:
    """Callable retail generator: ``gen(rng) -> list[RetailOrder]``.

    ``arrival_rate`` is TOTAL MARKET arrivals per block, not arrivals at our pool.
    That distinction is the point of pairing this with a deep normalizer: our
    pool's share of flow falls out of best-execution routing rather than being
    assumed. Calibrating "how much flow does my pool see" directly is what makes
    an equal-sized-rival model unrealistic.
    """

    def __init__(self, arrival_rate: float, quantiles_path: str | Path,
                 buy_prob: float = 0.5):
        # 0.5: retail is treated as noise flow; net directional flow belongs to
        # the fair-price path (see methodology.md).
        self.arrival_rate = float(arrival_rate)
        self.buy_prob = float(buy_prob)
        self.pcts, self.sizes = load_quantiles(quantiles_path)

    @property
    def label(self) -> str:
        return f"quantile(arr={self.arrival_rate:g},buy={self.buy_prob:g})"

    def __call__(self, rng) -> list[RetailOrder]:
        k = _poisson(self.arrival_rate, rng)
        out: list[RetailOrder] = []
        for _ in range(k):
            buy0 = rng.random() < self.buy_prob
            usd = _interp(rng.random() * 100.0, self.pcts, self.sizes)
            amount_in = int(usd * _SCALE)
            if amount_in <= 0:
                continue
            out.append(RetailOrder(zero_for_one=not buy0, amount_in=amount_in))
        return out
