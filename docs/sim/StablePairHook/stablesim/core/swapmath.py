"""Uniswap v4 swap math (``SqrtPriceMath`` / ``LiquidityAmounts`` / ``SwapMath``),
restricted to single-position constant-liquidity steps.

Exact-integer ports of ``SqrtPriceMath`` amount/price deltas and
``SwapMath.computeSwapStep``. The fee design never moves price itself:
it only chooses the LP fee, and the swap executes against pool liquidity with
this math. To run end-to-end swap simulations we therefore need the same
constant-product-within-a-range math v4 uses. The scored pool is a single
concentrated position, so a constant-``L`` model is exact while price stays
inside that position's range; :mod:`stablesim.core.pool` adds the range
bounds and partial-fill behaviour.
"""

from __future__ import annotations

from .fixedpoint import Q96, div_rounding_up, mul_div, mul_div_rounding_up

ONE_E6 = 1_000_000


# --- SqrtPriceMath: amount deltas -------------------------------------------
def get_amount0_delta(sqrt_a: int, sqrt_b: int, liquidity: int, round_up: bool) -> int:
    if sqrt_a > sqrt_b:
        sqrt_a, sqrt_b = sqrt_b, sqrt_a
    numerator1 = liquidity << 96
    numerator2 = sqrt_b - sqrt_a
    if round_up:
        return div_rounding_up(mul_div_rounding_up(numerator1, numerator2, sqrt_b), sqrt_a)
    return mul_div(numerator1, numerator2, sqrt_b) // sqrt_a


def get_amount1_delta(sqrt_a: int, sqrt_b: int, liquidity: int, round_up: bool) -> int:
    if sqrt_a > sqrt_b:
        sqrt_a, sqrt_b = sqrt_b, sqrt_a
    if round_up:
        return mul_div_rounding_up(liquidity, sqrt_b - sqrt_a, Q96)
    return mul_div(liquidity, sqrt_b - sqrt_a, Q96)


# --- SqrtPriceMath: next price from input -----------------------------------
def get_next_sqrt_price_from_amount0_rounding_up(
    sqrt_px96: int, liquidity: int, amount: int, add: bool
) -> int:
    if amount == 0:
        return sqrt_px96
    numerator1 = liquidity << 96
    if add:
        product = amount * sqrt_px96
        denominator = numerator1 + product
        if denominator >= numerator1:
            return mul_div_rounding_up(numerator1, sqrt_px96, denominator)
        return div_rounding_up(numerator1, (numerator1 // sqrt_px96) + amount)
    product = amount * sqrt_px96
    denominator = numerator1 - product
    return mul_div_rounding_up(numerator1, sqrt_px96, denominator)


def get_next_sqrt_price_from_amount1_rounding_down(
    sqrt_px96: int, liquidity: int, amount: int, add: bool
) -> int:
    if add:
        quotient = (amount << 96) // liquidity
        return sqrt_px96 + quotient
    quotient = mul_div_rounding_up(amount, Q96, liquidity)
    return sqrt_px96 - quotient


def get_next_sqrt_price_from_input(
    sqrt_px96: int, liquidity: int, amount_in: int, zero_for_one: bool
) -> int:
    if zero_for_one:
        return get_next_sqrt_price_from_amount0_rounding_up(sqrt_px96, liquidity, amount_in, True)
    return get_next_sqrt_price_from_amount1_rounding_down(sqrt_px96, liquidity, amount_in, True)


# --- LiquidityAmounts --------------------------------------------------------
def get_liquidity_for_amount0(sqrt_a: int, sqrt_b: int, amount0: int) -> int:
    if sqrt_a > sqrt_b:
        sqrt_a, sqrt_b = sqrt_b, sqrt_a
    intermediate = mul_div(sqrt_a, sqrt_b, Q96)
    return mul_div(amount0, intermediate, sqrt_b - sqrt_a)


def get_liquidity_for_amount1(sqrt_a: int, sqrt_b: int, amount1: int) -> int:
    if sqrt_a > sqrt_b:
        sqrt_a, sqrt_b = sqrt_b, sqrt_a
    return mul_div(amount1, Q96, sqrt_b - sqrt_a)


def get_liquidity_for_amounts(
    sqrt_px96: int, sqrt_a: int, sqrt_b: int, amount0: int, amount1: int
) -> int:
    """L for a position [sqrt_a, sqrt_b] holding (amount0, amount1) at sqrt_px96."""
    if sqrt_a > sqrt_b:
        sqrt_a, sqrt_b = sqrt_b, sqrt_a
    if sqrt_px96 <= sqrt_a:
        return get_liquidity_for_amount0(sqrt_a, sqrt_b, amount0)
    if sqrt_px96 < sqrt_b:
        l0 = get_liquidity_for_amount0(sqrt_px96, sqrt_b, amount0)
        l1 = get_liquidity_for_amount1(sqrt_a, sqrt_px96, amount1)
        return min(l0, l1)
    return get_liquidity_for_amount1(sqrt_a, sqrt_b, amount1)


def get_amounts_for_liquidity(
    sqrt_px96: int, sqrt_a: int, sqrt_b: int, liquidity: int
) -> tuple[int, int]:
    """(amount0, amount1) held by ``liquidity`` over [sqrt_a, sqrt_b] at sqrt_px96."""
    if sqrt_a > sqrt_b:
        sqrt_a, sqrt_b = sqrt_b, sqrt_a
    if sqrt_px96 <= sqrt_a:
        return get_amount0_delta(sqrt_a, sqrt_b, liquidity, False), 0
    if sqrt_px96 < sqrt_b:
        amount0 = get_amount0_delta(sqrt_px96, sqrt_b, liquidity, False)
        amount1 = get_amount1_delta(sqrt_a, sqrt_px96, liquidity, False)
        return amount0, amount1
    return 0, get_amount1_delta(sqrt_a, sqrt_b, liquidity, False)


# --- SwapMath.computeSwapStep (exact input, possibly clamped to a target) ----
def compute_swap_step(
    sqrt_px96: int,
    sqrt_target_x96: int,
    liquidity: int,
    amount_in: int,
    fee_pips: int,
    zero_for_one: bool,
) -> tuple[int, int, int, int]:
    """One exact-input swap step toward ``sqrt_target_x96`` (the range edge).

    Returns (sqrt_next, amount_in_consumed, amount_out, fee_amount). If the input
    is large enough to reach the target, price clamps to the target and only part
    of the input is consumed (the rest cannot fill: liquidity exhausted at the
    edge of the single position).
    """
    amount_remaining_less_fee = mul_div(amount_in, ONE_E6 - fee_pips, ONE_E6)
    sqrt_next = get_next_sqrt_price_from_input(
        sqrt_px96, liquidity, amount_remaining_less_fee, zero_for_one
    )

    reached_target = (
        (zero_for_one and sqrt_next < sqrt_target_x96)
        or (not zero_for_one and sqrt_next > sqrt_target_x96)
    )
    if reached_target:
        sqrt_next = sqrt_target_x96

    if zero_for_one:
        amount_in_used = get_amount0_delta(sqrt_next, sqrt_px96, liquidity, True)
        amount_out = get_amount1_delta(sqrt_next, sqrt_px96, liquidity, False)
    else:
        amount_in_used = get_amount1_delta(sqrt_px96, sqrt_next, liquidity, True)
        amount_out = get_amount0_delta(sqrt_px96, sqrt_next, liquidity, False)

    if not reached_target:
        # Whole input consumed within range: fee is the remainder above amount_in_used.
        fee_amount = amount_in - amount_in_used
    else:
        # Clamped at the edge: charge fee only on the portion actually swapped.
        fee_amount = mul_div_rounding_up(amount_in_used, fee_pips, ONE_E6 - fee_pips)

    return sqrt_next, amount_in_used, amount_out, fee_amount
