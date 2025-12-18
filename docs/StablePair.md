# Guidestar stablecoin algorithm

In the basic version of the algorithm, Guidestar owner sets the following parameters:

- reference price, RP
- optimal spread, optimalFeeSpread

For each swap, the protocol tries to set the fee so that the initial after-fee sell and buy prices are given by:

$$optimalSellPrice = RP \cdot (1 - optimalFeeSpread)$$

$$optimalBuyPrice = RP / (1 - optimalFeeSpread)$$

Here, by 'initial' prices we mean the price before the price impact of the swap itself, i.e., the buy or sell price for
the first $1 of the swap.

The most common value for $RP$ should be $1.0$.
Note that it is only possible to choose fees as described above when the AMM price is inside the optimal spread:
$$optimalSellPrice \leq P_{AMM} \leq optimalBuyPrice$$

Suppose the inequalities above do not hold and, for instance, we have $P_{AMM} > optimalBuyPrice.$
In this case, we set the buying fee to zero, so that the buying price is as close to $optimalBuyPrice$ as possible.

The selling fee is initially set so that the selling price is equal to $optimalSellPrice$.
Over time this fee will decline according to the following process.

- First, we calculate $targetSellPrice$ as
  $$targetPrice = optimalSpreadSell + (ammPrice - optimalBuy)/2.$$
- The selling fee reduces over time so that the selling price increases towards target price:
  $$sellPrice = targetPrice - k^{blocksPassed} \cdot (targetPrice - previousPrice)$$

where $blocksPassed$ is the number of blocks passed since the last transaction,
$previousPrice$ is the previous selling price at the time of the last swap,
and $k$ is a parameter set by the owner. For computational efficiency, the owner provides both $k$ and $\log k$.

## Automatic reference price

The owner can configure the reference price to automatically change over time. This is useful for pairs with a drifting
peg. \[Under construction\]

## Algorithm invariants

- Whenever $P_{AMM}$ is inside the optimal spread the buying and selling prices are constant.
  Otherwise, the spread between the buying and selling prices should be always bigger than the optimal spread.
- The total fee should not be greater than 99%.
- Fees always weakly decrease with time in the absence of transactions.
