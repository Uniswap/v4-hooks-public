# Spark Smart Pool Rehypothecating Hook

## Overview

A Uniswap v4 hook for Spark's stablecoin markets (USDS, USDC, USDT, pyUSD) that combines **spread pricing** with **Just-In-Time (JIT) liquidity positioning** and **rehypothecation to external yield sources**. All pool assets earn yield in ERC4626 vaults between swaps; liquidity is deployed to the pool only for the duration of each swap. Swaps leverage the Uniswap Active Liquidity Framework for discoverability and configurable spread pricing.

## Problem

Spark holds >$200M in LP on Curve, earning only swap fees. Capital sitting idle in Curve pools represents a significant missed revenue opportunity caused by capital inefficiency. Rehypothecating idle inventory into Morpho and other yield sources provides lending yield on top of trading fees. Curve's UI indicates that Spark's sUSDS-USDC pool ($50M TVL) only sees ~14% daily inventory turnover on average, implying that the vast majority of their TVL is almost always unproductive.

## Architecture

```
BaseALFHook (attestation, IALFHook, DeltaResolver)
  └── SpreadQuoterBase (PricingState, fee overrides, SwapSimulator, EIP-712)
        └── SparkSmartPoolHook (IHookStats)
              ├── JIT liquidity (beforeSwap / afterSwap)
              ├── ERC4626 vault integration per (pool, currency)
              ├── Per-pool share accounting for depositors
              ├── Pool initialization (initializePool)
              └── Configurable tick ranges per pool
```

Single contract. Multi-pool (state keyed by `PoolId`).

## JIT Liquidity

```
      BETWEEN SWAPS                        DURING A SWAP
┌─────────────────────────┐    ┌──────────────────────────────────────┐
│  All assets in ERC4626  │    │  beforeSwap:                         │
│  vaults earning yield   │    │    withdraw from vaults              │
│                         │    │    deploy LP at configured ticks     │
│  USDC → SparkLend vault │    │    return fee override (pricing)     │
│  USDS → held as ERC-20  │    │                                      │
│  (no vault configured)  │    │  pool executes swap against LP       │
│                         │    │                                      │
│  100% capital earning   │    │  afterSwap:                          │
│  yield at all times     │    │    remove LP from pool               │
│                         │    │    re-deposit to vaults              │
└─────────────────────────┘    └──────────────────────────────────────┘
```

**Key properties:**

- No persistent LP positions — liquidity is ephemeral (one swap lifetime)
- No tick management / auto-reposition — JIT liquidity is deployed fresh each swap
- 100% capital efficiency for yield — between swaps, everything that can be in vaults is deployed
- Operates within the swap's existing unlock context (no separate IUnlockCallback)

## Pricing

Implements a bid/ask model that applies a configurable spread over the pool's spot price:

- Per-pool `PricingState`: `bidFeePips`, `askFeePips`, `attestedDiscountBps`, `live`
- EIP-712 signed pricing state updates via hookData or direct
- Fee overrides applied via `LPFeeLibrary.OVERRIDE_FEE_FLAG`
- Attestation-aware discounts for known routing sources (optional)
- Indicative quotes computed against hypothetical JIT liquidity (for previewing swaps)

## TVL Discovery

Since we're rehypothecating all liquidity and pulling it in JIT, the pool will essentially show zero onchain pool liquidity between swaps, and aggregators and routers need an alternative way to discover capacity. `getReserves` and `getEffectiveLiquidity` are part of the Active Liquidity Framework's standard `IALFHook` interface.

```solidity
// from IALFHook:
function getReserves(PoolKey calldata key) external view returns (uint256 token0, uint256 token1);
function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint256 token0, uint256 token1);
```

`SparkSmartPoolHook` returns the sum of ERC-20 + ERC-6909 claims + ERC4626 vault balances for both of these functions. This allows routers to understand the actual token quantities available to the hook for servicing swaps.

## Per-Pool, Per-Asset Vault Configuration

Each `(PoolId, Currency)` pair maps to an optional ERC4626 vault:

- **USDS** → `address(0)` (no vault configured == no rehypothecation)
- **USDC** → ERC4626 vault A
- **USDT** → ERC4626 vault B
- **pyUSD** → ERC4626 vault C

Setting a vault to `address(0)` disables rehypothecation for that asset. Tokens are held as ERC-20 in the hook and deployed as JIT liquidity without vault interaction in this case. Any asset with a configured vault will have ~100% of that asset will be deposited to the vault at all times except (a) during a swap, and (b) after certain swaps where the pool manager doesn't have sufficient reserves to settle us during the hook lifecycle. The later case is a rare condition for large cap stablecoins, but it's possible because Uniswap v4's execution flow doesn't strictly require that the user settles their delta in full until the very end of the pool manager's unlock context. The implication is that there is a period that lasts at most from the end of one swap until the beginning of the next where the input amount of the first swap may be held as ERC6909 claims in the pool manager rather than allocated to the configured vault.

## Share Accounting

Per-pool shares represent proportional ownership of the pool's total assets (both currencies). These are **not** standard Uniswap v4 positions but rather an implementation-specific representation of pool exposure. The rehypothecation model is not compatible with standard v4 LP but works similarly:

- **Deposit**: User provides token0 + token1 proportional to pool ratio, receives N shares.
- **Withdraw**: User provides N shares (which are burned), receives proportional token0 + token1
- `externalDepositsEnabled` controls whether non-operator addresses can deposit (false means only the operator can deposit). Configurable per-pool by Spark's controller module.
- Share value increases as ERC4626 vaults accrue yield.
- It is possible that some portion of shares may be ineligible for redemption at any given time; all users and integrators must account for this.

## Access Control


| Function                                                      | Access                                  |
| ------------------------------------------------------------- | --------------------------------------- |
| `initializePool`, `setVault`, `setTickRange`, `configurePool` | Owner (spark governance)                |
| `addLiquidity`                                                | Operator(s) (or external if enabled)    |
| `removeLiquidity`                                             | Share holder                            |
| Pricing updates                                               | Owner (inherited from SpreadQuoterBase) |


## Pool Lifecycle

1. **Owner** calls `initializePool(key, sqrtPriceX96, pricing, tickRange, operator, externalDeposits)`
2. **Owner** calls `setVault(key, currency, vault)` for each currency
3. **Operator** calls `addLiquidity(key, shares)` to fund the pool
4. **Price signer** sends signed config updates as needed (via hookData or directly)
5. **Swaps** trigger JIT cycle automatically (beforeSwap → deploy, afterSwap → remove)

## Universal ERC4626 Vault Compatibility

Spark mentioned one specific vault provider so far (Morpho); more may be added to the list below, however any ERC4626-compliant vault is supported. Non-ERC4626 yield sources could be wrapped with a lightweight adapter for compatibility if desired.


| Protocol | ERC4626 Compatibility |
| -------- | --------------------- |
| Morpho   | Native ERC4626 vaults |


