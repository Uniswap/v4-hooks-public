"""Market price process used by the simulator.

Every constant of the process is in this file. Strategies observe the market
only through the trades that hit their pool.

Simulated with the exact OU transition (unbiased at any dt); paths are
warm-started from the stationary distribution.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass


@dataclass(frozen=True)
class OUParams:
    mu: float       # long-run mean (0 for a two-factor component)
    theta: float    # mean-reversion speed (per second)
    sigma: float    # instantaneous volatility (per sqrt(second))

    @property
    def half_life(self) -> float:
        return math.log(2) / self.theta

    @property
    def stationary_std(self) -> float:
        return self.sigma / math.sqrt(2 * self.theta)

    @classmethod
    def from_half_life_and_spread(cls, mu: float, half_life: float, stationary_std: float) -> "OUParams":
        theta = math.log(2) / half_life
        sigma = stationary_std * math.sqrt(2 * theta)
        return cls(mu=mu, theta=theta, sigma=sigma)

    def simulate(self, n_steps: int, dt: float, rng: random.Random) -> list[float]:
        """Exact OU path of length ``n_steps + 1``, warm-started from the stationary dist."""
        a = math.exp(-self.theta * dt)
        innov = self.stationary_std * math.sqrt(1 - a * a)
        x = self.mu + self.stationary_std * rng.gauss(0.0, 1.0)
        out = [x]
        for _ in range(n_steps):
            x = self.mu + (x - self.mu) * a + innov * rng.gauss(0.0, 1.0)
            out.append(x)
        return out

    def scaled(self, vol_mult: float = 1.0, speed_mult: float = 1.0) -> "OUParams":
        theta = self.theta * speed_mult
        s_inf = self.stationary_std * vol_mult
        return OUParams(self.mu, theta, s_inf * math.sqrt(2 * theta))


@dataclass(frozen=True)
class TwoFactorOU:
    mu: float
    fast: OUParams      # intraday component (zero-mean)
    slow: OUParams      # premium component (zero-mean)

    @property
    def stationary_std(self) -> float:
        return math.sqrt(self.fast.stationary_std ** 2 + self.slow.stationary_std ** 2)

    def simulate(self, n_steps: int, dt: float, rng: random.Random) -> list[float]:
        pf = self.fast.simulate(n_steps, dt, rng)
        ps = self.slow.simulate(n_steps, dt, rng)
        return [self.mu + f + s for f, s in zip(pf, ps)]

    def scaled(self, vol_mult: float = 1.0, speed_mult: float = 1.0) -> "TwoFactorOU":
        return TwoFactorOU(self.mu, self.fast.scaled(vol_mult, speed_mult),
                           self.slow.scaled(vol_mult, speed_mult))

    def summary(self) -> str:
        f, s = self.fast, self.slow
        return (f"two-factor: intraday(half-life {f.half_life/3600:.1f}h, {f.stationary_std*1e4:.2f}bp) + "
                f"premium(half-life {s.half_life/86400:.1f}d, {s.stationary_std*1e4:.2f}bp); "
                f"combined std {self.stationary_std*1e4:.2f}bp")


# --- environment parameters ---------------------------------------------
REFERENCE_PRICE = 1.0            # process anchor
BLOCK_SECONDS = 12.0             # one step per block
BLOCKS_PER_DAY = 7200

TWO_FACTOR_FIT = {
    "intraday_half_life_s": 14 * 3600,
    "intraday_std": 1.4e-4,
    "premium_half_life_s": 10 * 86400,
    "premium_std": 4.5e-4,
}

# --- stochastic volatility -----------------------------------------------
# The vol multiplier is CONTINUOUS: log(m) is itself an Ornstein-Uhlenbeck
# process. This replaced a 2-state Markov (calm/hot) chain after direct
# testing on the data.
#
# Fit on 576 days of Binance USDC/USDT daily realized vol (2024-12..2026-07),
# hourly-return RV corrected for tick quantization, the 2025-10-10 venue
# dislocation excluded, gap-aware transitions (a^k over multi-day holes):
#
#   model                 params   BIC
#   latent OU + noise        4     870.3   <- used here
#   AR(1), no obs noise      3     916.6
#   2-state Gaussian HMM     6     942.4
#   iid 2-Gaussian mixture   5    1073.0
#   single Gaussian          3    1078.9
#
# The discrete-regime model loses by dBIC 72 and ranks below even a plain
# AR(1). log-RV is unimodal (skew +0.003) and a 2-component mixture barely
# beats one Gaussian, so there are no two distinct vol states to switch
# between: apparent "regimes" are excursions of a continuous process. The
# 21.9d half-life comes from the autocorrelation of 576 daily observations.
VOL_HALF_LIFE_DAYS = 21.9        # latent log-vol mean reversion
VOL_LOG_SD = 0.438               # stationary sd of log(m)
VOL_THETA = math.log(2) / (VOL_HALF_LIFE_DAYS * 86400.0)   # per second

# LEVEL: E[m^2] == 1 exactly. The multiplier REDISTRIBUTES variance over time;
# it must not add any.
#
# This is easy to get wrong. TWO_FACTOR_FIT comes from a variogram over the
# FULL sample, so those stds already are the *average* volatility across calm
# and turbulent stretches. Treating the fit as a "calm" level and multiplying
# up for hot double-counts variance. Setting mu = -sd^2 makes the simulated
# market's unconditional variance equal the fitted variance, which is the only
# choice reproducing the observed variogram.
VOL_LOG_MU = -(VOL_LOG_SD ** 2)   # = -0.191844  ->  E[m^2] = exp(2mu + 2sd^2) = 1


def two_factor(mu: float = REFERENCE_PRICE, vol_mult: float = 1.0) -> TwoFactorOU:
    """The constant-vol market process, optionally vol-scaled."""
    f = TWO_FACTOR_FIT
    fast = OUParams.from_half_life_and_spread(0.0, f["intraday_half_life_s"], f["intraday_std"])
    slow = OUParams.from_half_life_and_spread(0.0, f["premium_half_life_s"], f["premium_std"])
    tf = TwoFactorOU(mu=mu, fast=fast, slow=slow)
    return tf.scaled(vol_mult) if vol_mult != 1.0 else tf


@dataclass(frozen=True)
class StochasticVolTwoFactorOU:
    """Two-factor OU whose vol multiplier is itself a (log-)OU process.

    Each block, ``log m`` mean-reverts toward ``log_mu`` and takes a Gaussian
    innovation; ``m = exp(log m)`` then scales the OU *innovation* std of both
    price factors. Volatility therefore clusters continuously: there are no
    discrete states to classify, only a latent level to track.

    RNG draw order is FROZEN (seed reproducibility): warm start draws
    (z_vol, z_fast, z_slow), then per block (z_vol, z_fast, z_slow).
    New parameters must extend, never reorder, this schedule.

    Three gaussians are drawn per block. Python's ``gauss`` caches the second
    value of each Box-Muller pair, so with an odd number of draws per block the
    cache alternates between empty and full at block boundaries; any
    reimplementation has to reproduce that to match the draws.
    """

    base: TwoFactorOU
    log_mu: float = VOL_LOG_MU
    log_sd: float = VOL_LOG_SD
    theta: float = VOL_THETA

    @property
    def mean_sq_mult(self) -> float:
        """E[m^2]: the market's average variance multiplier."""
        return math.exp(2 * self.log_mu + 2 * self.log_sd ** 2)

    def simulate(self, n_steps: int, dt: float, rng: random.Random
                 ) -> tuple[list[float], list[float]]:
        """Simulate ``n_steps + 1`` prices; also return the per-block vol multiplier.

        Warm start: log-vol from its stationary distribution, then each price
        factor from its vol-conditional stationary distribution.
        """
        f, s = self.base.fast, self.base.slow
        af = math.exp(-f.theta * dt)
        as_ = math.exp(-s.theta * dt)
        innov_f = f.stationary_std * math.sqrt(1 - af * af)
        innov_s = s.stationary_std * math.sqrt(1 - as_ * as_)

        av = math.exp(-self.theta * dt)
        innov_v = self.log_sd * math.sqrt(1 - av * av)

        lv = self.log_sd * rng.gauss(0.0, 1.0)          # centred log-vol state
        m = math.exp(self.log_mu + lv)
        xf = f.stationary_std * m * rng.gauss(0.0, 1.0)
        xs = s.stationary_std * m * rng.gauss(0.0, 1.0)
        prices = [self.base.mu + xf + xs]
        mults = [m]
        for _ in range(n_steps):
            lv = lv * av + innov_v * rng.gauss(0.0, 1.0)
            m = math.exp(self.log_mu + lv)
            xf = xf * af + innov_f * m * rng.gauss(0.0, 1.0)
            xs = xs * as_ + innov_s * m * rng.gauss(0.0, 1.0)
            prices.append(self.base.mu + xf + xs)
            mults.append(m)
        return prices, mults

    def summary(self) -> str:
        return (f"stochastic-vol {self.base.summary()} | log-vol OU "
                f"(half-life {VOL_HALF_LIFE_DAYS:.1f}d, sd {self.log_sd:.3f}, "
                f"E[m^2] {self.mean_sq_mult:.3f})")


def stochastic_vol(mu: float = REFERENCE_PRICE) -> StochasticVolTwoFactorOU:
    """The v2 market process: two-factor OU under a log-OU stochastic vol."""
    return StochasticVolTwoFactorOU(base=two_factor(mu=mu))
