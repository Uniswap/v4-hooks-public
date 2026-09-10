"""Exact Uniswap v4 ``TickMath.getSqrtPriceAtTick`` (integer, wei-accurate).

Converts onchain tick bounds into exact sqrtPriceX96 values for the pool
simulator.
"""

from __future__ import annotations

MIN_TICK = -887272
MAX_TICK = 887272
_Q256_MASK = (1 << 256) - 1


def get_sqrt_ratio_at_tick(tick: int) -> int:
    """sqrtPriceX96 at ``tick`` = sqrt(1.0001**tick) * 2**96 (exact)."""
    if not (MIN_TICK <= tick <= MAX_TICK):
        raise ValueError(f"tick {tick} out of range")
    abs_tick = -tick if tick < 0 else tick

    ratio = 0xfffcb933bd6fad37aa2d162d1a594001 if (abs_tick & 0x1) else 0x100000000000000000000000000000000
    if abs_tick & 0x2:
        ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128
    if abs_tick & 0x4:
        ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128
    if abs_tick & 0x8:
        ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128
    if abs_tick & 0x10:
        ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128
    if abs_tick & 0x20:
        ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128
    if abs_tick & 0x40:
        ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128
    if abs_tick & 0x80:
        ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128
    if abs_tick & 0x100:
        ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128
    if abs_tick & 0x200:
        ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128
    if abs_tick & 0x400:
        ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128
    if abs_tick & 0x800:
        ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128
    if abs_tick & 0x1000:
        ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128
    if abs_tick & 0x2000:
        ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128
    if abs_tick & 0x4000:
        ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128
    if abs_tick & 0x8000:
        ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128
    if abs_tick & 0x10000:
        ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128
    if abs_tick & 0x20000:
        ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128
    if abs_tick & 0x40000:
        ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128
    if abs_tick & 0x80000:
        ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128

    if tick > 0:
        ratio = _Q256_MASK // ratio

    # Round the 128.128 ratio down to a Q96 sqrt price (round up if any remainder).
    return (ratio >> 32) + (1 if (ratio & 0xffffffff) else 0)
