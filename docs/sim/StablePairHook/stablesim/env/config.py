"""Environment constants for the two-venue simulation.

Everything here is either measured from on-chain data (and says so) or is a
structural constant of the environment. Order flow comes from the empirical size
table in ``data/`` at the arrival rate given on the command line.
"""

from __future__ import annotations

from dataclasses import dataclass

# --- paths and time ---------------------------------------------------------
DAYS_PER_PATH = 365
BLOCKS_PER_DAY = 7200                    # 12s blocks
BLOCKS_PER_PATH = DAYS_PER_PATH * BLOCKS_PER_DAY

# --- the pool under test ----------------------------------------------------
TVL_USD = 10_000_000.0
POOL_HALF_WIDTH_BPS = 200.0              # default range; published runs use --half-width-bps 20
SCALE = 10**6                            # raw token units (6-decimal tokens)
MAX_FEE_E6 = 10_000                      # 100bp (1%) hard fee cap, mirrors StablePair Hook

# --- the rest-of-market venue -----------------------------------------------
# Exogenous market reality, not a tunable: the deep incumbent pool a new pool
# launches against. Fee is the largest real pool's posted fee. Depth is set per
# run via --norm-tvl (published runs: $50M at +-20bp = $25B v2-equivalent,
# pinned by the measured impact curve).
RIVAL_FEE_E6 = 7                         # 0.07 bp


@dataclass(frozen=True)
class PathConfig:
    seed: int
    blocks: int = BLOCKS_PER_PATH



# Retail draws from its own stream, seeded at an offset from the path seed, so
# the frozen price draw order is untouched. Any value works as long as it never
# collides with a path seed.
RETAIL_SEED_OFFSET = 1_000_003
# Integration draws use their own stream so the retail draws stay untouched.
INTEGRATION_SEED_OFFSET = 2_000_003
