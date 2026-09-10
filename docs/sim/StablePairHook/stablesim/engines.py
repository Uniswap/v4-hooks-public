"""The fee designs compared in the README.

Each engine is a fee shape parameterised by a fee level: a flat fee, the naive
directional design, the flipped design, and StablePair Hook's band-plus-decay
structure. The README compares them at the same fee setting.

Why native Python rather than Solidity in an EVM: the shape comparison does not
depend on the EVM, and native is about 1.4x faster per path. The engine for
StablePair Hook is a float port of its fee calculation.

All of these are stateless: the fee depends only on the price they are shown and
the trade direction. That matters for the per-block fee cache: the harness
quotes each direction once per block from block-start state, so a stateless
engine sees exactly one well-defined input per (block, direction).
"""

from __future__ import annotations

from stablesim.core.fixedpoint import Q96
from stablesim.core.pool import FeeQuote
from stablesim.env.config import MAX_FEE_E6

# The peg. Prices are token1/token0 with equal decimals, so 1:1 is sqrt = 2^96.
PEG_SQRT_X96 = Q96


def moving_toward_peg(sqrt_price_x96: int, zero_for_one: bool) -> bool:
    """Would this swap move the pool's price toward 1:1?

    `zero_for_one` sells token0, which pushes price DOWN. So a swap moves toward
    the peg when the pool is above it and the swap pushes down, or below it and
    the swap pushes up.

    Exactly at the peg both directions are reported as "toward", which charges
    the higher fee. That is the conservative choice: the alternative hands out
    free trades at 1:1, and it is a measure-zero case in practice, since the
    pool sits exactly on 2^96 only at initialisation.
    """
    if zero_for_one:
        return sqrt_price_x96 >= PEG_SQRT_X96
    return sqrt_price_x96 <= PEG_SQRT_X96


class Flat:
    """One fee, both directions. The thing the shape has to beat."""

    kind = "flat"

    def __init__(self, fee_e6: int):
        self.fee_e6 = int(fee_e6)

    @property
    def label(self) -> str:
        return f"flat({self.fee_e6})"

    def before_swap(self, block_number: int, current_sqrt_price_x96: int,
                    zero_for_one: bool, commit: bool = True) -> FeeQuote:
        return FeeQuote(fee_e6=self.fee_e6)


class HookShape:
    """The naive directional design: free away from the peg, a fixed fee toward it.

    The reasoning it encodes: the true price mean-reverts to 1:1, so flow that
    pushes the pool AWAY from the peg is trading against the reversion and is
    profitable for the LP to take: price it at zero and win it from the rival.
    Flow moving TOWARD the peg is the corrective side, the arbitrage, so tax it.
    """

    kind = "hook"

    def __init__(self, toward_fee_e6: int, away_fee_e6: int = 0):
        self.toward_fee_e6 = int(toward_fee_e6)
        self.away_fee_e6 = int(away_fee_e6)

    @property
    def label(self) -> str:
        return f"hook({self.away_fee_e6}/{self.toward_fee_e6})"

    def before_swap(self, block_number: int, current_sqrt_price_x96: int,
                    zero_for_one: bool, commit: bool = True) -> FeeQuote:
        toward = moving_toward_peg(current_sqrt_price_x96, zero_for_one)
        return FeeQuote(fee_e6=self.toward_fee_e6 if toward else self.away_fee_e6)


class InvertedHook:
    """The flipped design: taxed away from the peg, free or cheaper toward it.

    Deliberately the wrong way round, and an abstraction of the common design
    for pegged pools, which raises the fee on trades pushing the price off the
    peg. If HookShape wins only because ANY directional split beats a flat fee,
    this wins too and the comparison proves nothing about the peg reasoning. It
    exists to make the result falsifiable.
    """

    kind = "inverted"

    def __init__(self, away_fee_e6: int, toward_fee_e6: int = 0):
        self.away_fee_e6 = int(away_fee_e6)
        self.toward_fee_e6 = int(toward_fee_e6)

    @property
    def label(self) -> str:
        return f"inverted({self.away_fee_e6}/{self.toward_fee_e6})"

    def before_swap(self, block_number: int, current_sqrt_price_x96: int,
                    zero_for_one: bool, commit: bool = True) -> FeeQuote:
        toward = moving_toward_peg(current_sqrt_price_x96, zero_for_one)
        return FeeQuote(fee_e6=self.toward_fee_e6 if toward else self.away_fee_e6)


class BandDecayShape:
    """StablePair Hook's full structure: optimal-range band + decaying fee.

    Faithful float port of StablePair Hook's fee calculation (RP = 1.0),
    parameterized for ablation:

      band [1-f*, 1/(1-f*)] in PRICE space, f* = optimal_fee_e6:
        INSIDE:  each direction's fee pins the pre-impact execution price at
                 the band edge (sells at the lower bound, buys at the upper):
                 a constant two-sided quote around RP regardless of where the
                 pool sits. At P = RP both directions pay exactly f*.
        OUTSIDE: away direction pays 0; toward direction pays a DECAYING fee:
                 starts at the far-boundary-pinning fee when the band is first
                 exited (or adjusted to preserve pre-impact price if the pool
                 moved further out), then decays per block by factor k toward
                 target = far - close*TM/100 (TM=100 here, the tightest target).

      k_permille: 990 = 0.99/block; 1000 = frozen (no decay,
      stays at the far-boundary fee); 0 = instant (no decay, jumps to target).

    State advances once per block at quote time, from block-start price: the
    contract updates lazily at the first swap of a block, which sees the same
    price; the one divergence is that the movement-adjustment branches here
    observe the price EVERY block rather than only at swap blocks. The upward
    adjustment composes exactly ((1-fee) scales by the price ratio), so this is
    the continuous-observation variant of the same rule.
    """

    kind = "band"

    def __init__(self, optimal_fee_e6: int, k_permille: int, target_mult: int = 100):
        self.f_star = int(optimal_fee_e6) / 1e6
        self.k = int(k_permille) / 1000.0
        self.tm = int(target_mult) / 100.0
        self._block = None          # last state-update block
        self._prev_p = None         # block-start price at that update
        self._decay_fee = None      # None == inside band (UNDEFINED sentinel)
        self._snap = None           # (below_rp, inside, close, far, decay_fee)

    @property
    def label(self) -> str:
        return f"band({int(self.f_star*1e6)},k={int(self.k*1000)})"

    def _advance(self, block: int, p: float) -> None:
        r = p if p < 1.0 else 1.0 / p            # min(P, 1/P), ratio <= 1
        g = 1.0 - self.f_star
        close = 1.0 - r / g                       # >0 means outside the band
        far = 1.0 - g * r
        below = p < 1.0
        if close <= 0.0:
            decay = None                          # inside: no decay state
        else:
            prev_p, prev = self._prev_p, self._decay_fee
            if prev is None or prev_p is None or (prev_p < 1.0) != below:
                start = far                       # just left band / crossed RP
            elif below == (p < prev_p):
                m = min(p, prev_p) / max(p, prev_p)
                start = 1.0 - m * (1.0 - prev)    # moved further out: adjust
            elif prev > far:
                start = far                       # moved in: cap at new far
            else:
                start = prev
            target = far - close * self.tm
            dt = 1 if self._block is None else max(1, block - self._block)
            decay = target + (self.k ** dt) * (start - target)
        self._block, self._prev_p, self._decay_fee = block, p, decay
        self._snap = (below, close <= 0.0, r, far, decay)

    def before_swap(self, block_number: int, current_sqrt_price_x96: int,
                    zero_for_one: bool, commit: bool = True) -> FeeQuote:
        if block_number != self._block:
            self._advance(block_number, (current_sqrt_price_x96 / Q96) ** 2)
        below, inside, r, far, decay = self._snap
        g = 1.0 - self.f_star
        if inside:
            # pin pre-impact execution at the band edge, per direction
            fee = (1.0 - g / r) if (below == zero_for_one) else (1.0 - g * r)
        else:
            fee = 0.0 if (below == zero_for_one) else decay
        # Clamp into the legal fee range: a large deviation can push the
        # deviation-pinned fee past the 1% cap.
        return FeeQuote(fee_e6=min(MAX_FEE_E6, max(0, round(fee * 1e6))))


def build(spec: tuple) -> Flat | HookShape | InvertedHook:
    """Construct an engine from a picklable spec, inside the worker process.

    Multiprocessing uses spawn, so workers re-import this module and must build
    their own engine rather than receive one over the wire.
    """
    kind, a, b = spec
    if kind == "flat":
        return Flat(a)
    if kind == "hook":
        return HookShape(toward_fee_e6=a, away_fee_e6=b)
    if kind == "inverted":
        return InvertedHook(away_fee_e6=a, toward_fee_e6=b)
    if kind == "band":
        return BandDecayShape(optimal_fee_e6=a, k_permille=b)
    if kind == "bandtm":
        # Full config-space point: a = target_mult*1000 + optimal_fee_e6
        # (both config fields of the live contract), b = k in ppm.
        e = BandDecayShape(optimal_fee_e6=a % 1000, k_permille=1000,
                           target_mult=a // 1000)
        e.k = int(b) / 1e6
        return e
    if kind == "band6":
        # k in parts-per-million, for mapping the fine end of the decay curve
        # (k_permille cannot express 0.9995). Same engine, finer dial.
        e = BandDecayShape(optimal_fee_e6=a, k_permille=1000)
        e.k = int(b) / 1e6
        return e
    raise ValueError(f"unknown engine kind {kind!r}")
