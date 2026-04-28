# ALF: Formal Specification

**Version:** 0.3.0-draft
**Authors:** Uniswap Labs Protocols Team
**Status:** Draft
**Last Updated:** April 2026

---

# Overview

This document specifies the interfaces, contracts, behaviors, and invariants of the ALF system as implemented on this branch. It is intended as an implementation reference. For motivation, rationale, and product context, see `alf-design.md`.

## System Components

All ALF code lives under `src/alf/`. Components are split into shared bases (inherited by every quoter), reference quoter strategies, and the auction hook.

| Component | Type | Path | Mutability | Deployment |
| --- | --- | --- | --- | --- |
| `IALFHook` | Interface | `src/alf/interfaces/IALFHook.sol` | — | — |
| `ALFHookData` | Struct | `src/alf/interfaces/IALFHook.sol` | — | — |
| `BaseALFHook` | Abstract contract | `src/alf/base/BaseALFHook.sol` | Per-pool curve-update hash; `priceSigner` (settable) | Extended by quoter hooks |
| `SpreadQuoterBase` | Abstract contract | `src/alf/base/SpreadQuoterBase.sol` | Per-pool `PricingState`, `activeLowerTick` | Extended by spread quoters |
| `PoolVault` | Abstract contract | `src/alf/base/PoolVault.sol` | Per-pool share math + asset tracking | Extended by rehypothecating hooks |
| `SwapSimulator` | Library | `src/alf/libraries/SwapSimulator.sol` | — | Linked into hooks |
| `PairLib` | Library | `src/alf/libraries/PairLib.sol` | — | Linked into hooks |
| `ALFProtocolFees` | Abstract contract | `src/alf/base/ALFProtocolFees.sol` | — | Extended by `ALFMultiplexer` |
| `SimpleSpreadQuoterHook` | Contract (reference) | `src/alf/SimpleSpreadQuoterHook.sol` | Per-pool `PricingState`, `authorizedLPs` | One per quoter per pair |
| `SmartPoolHook` | Contract (reference) | `src/alf/SmartPoolHook.sol` | Per-pool `PoolState`, `PoolVault` storage | One per quoter per pair |
| `ALFMultiplexer` | Contract | `src/alf/ALFMultiplexer.sol` | Stateless | One per chain |
| `AuctionTypes` | Structs | `src/alf/types/AuctionTypes.sol` | — | — |

`AttestationRegistry` is **not** part of the system. Attestation handling is a per-hook concern — see [Attestation Extension Point](#attestation-extension-point).

## Dependencies

- Uniswap v4 PoolManager
- Uniswap v4 BaseHook (`src/base/BaseHook.sol` in this repo)
- Uniswap v4 DeltaResolver (via v4-periphery)
- Uniswap v4 core types (`PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `BeforeSwapDelta`)
- v4-periphery `LiquidityAmounts`
- OpenZeppelin: `IERC4626`, `IERC20`, `SafeERC20`, `ReentrancyGuardTransient`, `Ownable2Step`, `EIP712`, `ECDSA` (used by `SmartPoolHook` and `SpreadQuoterBase`)

## Conventions

- `PoolId` is derived from `PoolKey` via `PoolKey.toId()`.
- "Pair" refers to an unordered `(Currency, Currency)` tuple. "Pool" refers to a specific `PoolKey` which includes the pair, fee, tick spacing, and hook address.
- Gas values are specified as `uint32`, supporting up to ~4.29 billion gas units. This should be more than sufficient for all current use cases and future-proof for the foreseeable future of typical EVMs.
- All view functions called for quoting purposes MUST be invoked via `staticcall`.
- All curve-update signatures use EIP-712 typed data; the verifying contract is the quoter hook itself.

# Standard hookData Envelope

ALF hooks accept a uniform hookData shape so that routers, the auction hook, and quoter hooks all decode the same payload:

```solidity
struct ALFHookData {
    bytes attestationData; // ABI-encoded attestation payload, or empty
    bytes curveUpdateData; // ABI-encoded signed curve update, or empty
}
```

Callers MUST encode hookData as `abi.encode(ALFHookData(...))` for any swap that needs to forward attestation or curve-update payloads. Empty `hookData` (`bytes("")`) is also valid and means "no attestation, no curve update."

`BaseALFHook._resolveHookData(bytes calldata hookData)` decodes this envelope and resolves attestation in one step, returning `(bytes curveUpdateData, bool isAttested, address attester)`.

# Attestation Extension Point

Attestation verification is delegated to each hook via a virtual on `BaseALFHook`:

```solidity
function _resolveAttestation(bytes memory attestationData)
    internal view virtual returns (bool isAttested, address attester);
```

The base implementation returns `(false, address(0))`. Subclasses that want to consume attestation override this method and verify the payload using whatever trust model fits the maker's strategy (typically EIP-712 against an owner-managed signer, often the same `priceSigner` used for signed curve updates).

There is **no shared registry contract**. Makers choose:

- Their own attester set (no governance coordination).
- Their own EIP-712 domain.
- What checks to layer on top (e.g., binding to `swapHash`, deadline enforcement, swapper match).

The base only handles decoding the envelope and routing the raw `attestationData` bytes to the override. Hooks that don't override `_resolveAttestation` see all flow as unattested.

# IALFHook

A standard interface implemented by ALF hooks on top of the v4 hook interface. Provides a uniform way for the router and auction hook to query indicative quotes, simulate price-bounded fills, and read hook metadata.

## Interface

```solidity
interface IALFHook {
    function getIndicativeQuote(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    ) external view returns (uint256 outputAmount);

    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external view returns (uint256 amountIn, uint256 amountOut);

    function isLive() external view returns (bool);
    function maxGas() external view returns (uint32);

    function getReserves(PoolKey calldata key)
        external view returns (uint256 token0, uint256 token1);
    function getEffectiveLiquidity(PoolKey calldata key)
        external view returns (uint256 token0, uint256 token1);
}
```

`hookData` is the standard `ALFHookData` envelope (or empty bytes). Hooks that ignore hookData on indicatives (e.g., `SmartPoolHook`) still accept the parameter for ABI uniformity.

## Behavioral Requirements

- **View-only.** All `IALFHook` methods MUST be callable via `staticcall`. They MUST NOT modify state.
- **Non-reverting.** `getIndicativeQuote` and `swapToPrice` SHOULD NOT revert. If the quoter cannot price a swap (insufficient liquidity, unsupported direction, hook not live, etc.), it SHOULD return `0` (or `(0, 0)` for `swapToPrice`). Quoters that revert will be deprioritized by the router's reputation model and skipped by the auction hook.
- **Gas-bounded.** `getIndicativeQuote` MUST execute within the gas limit declared by `maxGas()`. Consumers will call with `{gas: maxGas}` and treat OOG conditions as a failure.
- **Attestation handling.** If `attestationData` (within the `ALFHookData` envelope) is non-empty, the quoter MAY offer preferential pricing by overriding `_resolveAttestation`. The base default is no-op, so hooks that don't override see all flow as unattested.
- **Consistency.** The indicative quote SHOULD be consistent with the price `beforeSwap` would produce given the same parameters in the same block. Persistent divergence between indicative and executed prices will cause router deprioritization and may trigger auction-hook tolerance checks (see `strictTolerancePips`).
- **Reserve reporting.** `getReserves` reports total assets under management (vault deposits, ERC-6909 claims, ERC-20 balances tracked by the hook); `getEffectiveLiquidity` reports the subset that's immediately available for swap settlement (e.g., excluding vault assets that can't be redeemed at current utilization). Hooks with no off-pool reserves return `(0, 0)` for both.

# BaseALFHook

Abstract base contract that quoter hooks SHOULD extend. Provides hookData decoding, the `IALFHook` defaults, signed-curve-update bookkeeping, and `DeltaResolver` settlement helpers.

## Inheritance

`BaseALFHook` inherits from both `BaseHook` and `DeltaResolver`. This dual-inheritance pattern (mirroring `BaseTokenWrapperHook` in v4-periphery) gives quoter hooks access to `_settle()` and `_take()` for delta resolution during swap lifecycle hooks. The required `_pay()` is implemented to transfer tokens directly to the PoolManager:

```solidity
function _pay(Currency token, address, uint256 amount) internal override {
    token.transfer(address(poolManager), amount);
}
```

## Surface

```solidity
abstract contract BaseALFHook is BaseHook, DeltaResolver, IALFHook {
    uint32 private immutable _maxGas;

    address public priceSigner; // Settable by subclass-provided owner controls
    mapping(PoolId => mapping(uint256 => bytes32)) internal _curveUpdateHash;

    error ExpiredUpdate();
    error PoolMismatch();
    error ConflictingCurveUpdate();
    error InvalidPriceSigner();

    event PriceSignerUpdated(address indexed newSigner);

    constructor(IPoolManager _poolManager, uint32 maxGas_) BaseHook(_poolManager);

    // ──── IALFHook defaults ────
    function maxGas() external view override returns (uint32);
    function getIndicativeQuote(PoolKey, bool, int256, bytes calldata)
        external view virtual override returns (uint256);
    function isLive() external view virtual override returns (bool); // abstract
    function getReserves(PoolKey) external view virtual override returns (uint256, uint256);          // (0, 0)
    function getEffectiveLiquidity(PoolKey) external view virtual override returns (uint256, uint256); // (0, 0)
    function swapToPrice(PoolKey, bool, int256, uint160, bytes calldata)
        external view virtual override returns (uint256, uint256);                                     // (0, 0)

    // ──── HookData / attestation ────
    function _resolveHookData(bytes calldata hookData)
        internal view returns (bytes memory curveUpdateData, bool isAttested, address attester);
    function _resolveAttestation(bytes memory attestationData)
        internal view virtual returns (bool isAttested, address attester);

    // ──── Curve-update bookkeeping ────
    function _validateCurveUpdateMeta(PoolId poolId, PoolId updatePoolId, uint256 deadline) internal view;
    function _checkAndMarkCurveUpdate(PoolId poolId, bytes memory curveUpdateData) internal returns (bool isNew);

    // ──── Pricing (abstract) ────
    function _price(PoolKey, bool, int256, bool isAttested, address attester)
        internal view virtual returns (uint256);
}
```

## Behavior

- **`getIndicativeQuote` default:** decodes `ALFHookData`, resolves attestation, calls `_price(...)` with `(isAttested, attester)`. Subclasses overriding `getIndicativeQuote` MUST preserve the no-revert behavior described above.
- **`_resolveHookData`:** returns empty curve update + `(false, 0)` attestation when `hookData` is empty; otherwise decodes the envelope and routes `attestationData` through `_resolveAttestation`.
- **`_validateCurveUpdateMeta`:** reverts `PoolMismatch` if the update's `poolId` doesn't match the swap's pool, and `ExpiredUpdate` if `block.timestamp > deadline`.
- **`_checkAndMarkCurveUpdate`:** records the first `keccak256(curveUpdateData)` seen for a given `(poolId, block.number)`. Returns `true` if this is the first call in the block (caller should apply the update); returns `false` if the same hash is replayed; reverts `ConflictingCurveUpdate` if a different hash is submitted in the same block.
- **`isLive`:** abstract — subclass MUST implement.

## Invariants

- **No registry coupling.** `BaseALFHook` does not depend on any external registry contract.
- **No-op attestation default.** Without subclass override, every swap is treated as unattested (`isAttested = false`, `attester = address(0)`).
- **One curve update per pool per block.** Once a curve update is committed for `(poolId, block.number)`, only the same payload may be re-submitted in that block.

# SpreadQuoterBase

Abstract base for bid/ask spread quoters. Builds on `BaseALFHook` with EIP-712 signed curve updates, fee-override execution, and single-tick LP enforcement.

## Inheritance

`SpreadQuoterBase` inherits from `BaseALFHook`, `EIP712`, and `Ownable2Step`. The owner manages `priceSigner` and pricing state.

## State

```solidity
struct PricingState {
    uint24 bidFeePips; // Fee override for zeroForOne swaps (pips, max 1_000_000)
    uint24 askFeePips; // Fee override for oneForZero swaps (pips, max 1_000_000)
    bool live;
}

mapping(PoolId => PricingState) public pricingState;
mapping(PoolId => int24) public activeLowerTick;
```

## Curve update payload

```solidity
abi.encode(
    PricingState newState,
    PoolId poolId,
    uint256 deadline,
    bytes signature
)
```

The signature is EIP-712 over:

```solidity
bytes32 PRICING_UPDATE_TYPEHASH = keccak256(
    "PricingUpdate(uint24 bidFeePips,uint24 askFeePips,bool live,bytes32 poolId,uint256 deadline)"
);
```

verified against `priceSigner`.

## beforeSwap behavior

1. Decode `ALFHookData` and resolve any curve update.
2. If a curve update is present and is the first for `(poolId, block.number)`, validate metadata + signature, then commit the new `PricingState` via `_commitPricingState`.
3. If `state.live == false`, return `(selector, ZERO_DELTA, 0)` — no override, swap executes at the pool's stored fee.
4. Otherwise, return `(selector, ZERO_DELTA, feePips | OVERRIDE_FEE_FLAG)` where `feePips = state.bidFeePips` (zeroForOne) or `state.askFeePips` (oneForZero).

## Indicative quote behavior

`getIndicativeQuote` overlays any unsigned hookData curve update on top of stored state for simulation only (no signature verification, no storage writes), then delegates to `SwapSimulator.simulateSwap` against the pool's current state with the effective fee. The unsigned overlay is documented as a non-binding caveat — production aggregators SHOULD override `getIndicativeQuote` to verify signatures or ignore hookData entirely if the quoter is trust-sensitive.

`swapToPrice` follows the same pattern but delegates to `SwapSimulator.simulateSwapToPrice` with the supplied price limit.

## LP enforcement

Subclasses opt into single-tick LP enforcement by calling `_enforceActiveTick(key, params)` from `_beforeAddLiquidity`. The check rejects positions whose width is not exactly `tickSpacing` and whose lower tick doesn't match `activeLowerTick[poolId]`. The active tick is auto-set to the floor-aligned current tick on `_afterInitialize` and may be updated by the owner via `setActiveTick`.

## Owner functions

- `updatePricingState(PoolKey, PricingState)` — commit new pricing (validates fee bounds, syncs the PM's stored dynamic LP fee).
- `setPoolLive(PoolKey, bool)` — toggle liveness; sets the PM's stored fee to 0 when going offline.
- `setPriceSigner(address)` — authorize the EIP-712 signer for hookData curve updates. Setting to `address(0)` is permitted and disables signed updates.
- `setActiveTick(PoolKey, int24)` — relocate the LP concentration tick.

## Invariants

- **Fee bounds.** Every commit of `PricingState` validates `bidFeePips ≤ MAX_LP_FEE` and `askFeePips ≤ MAX_LP_FEE` (1_000_000 = 100%). Without this, fees > 100% break v4's swap math (denominator underflow) and could let an owner / compromised priceSigner brick or extract from the pool.
- **Direction-aware fees.** Bid and ask fees are independent and applied per swap direction.
- **Stored fee is informational.** The PM's stored dynamic LP fee tracks `max(bidFeePips, askFeePips)` for offchain consumers. Per-swap pricing comes from the override returned in `_beforeSwap`.

# PoolVault

Abstract base for hooks that rehypothecate idle inventory into ERC4626 vaults and account for LP positions as proportional shares.

## State

PoolVault tracks per-pool:

- ERC4626 vault shares for each token (vault deposits earning yield).
- ERC-6909 claims held in the PoolManager.
- Per-pool ERC-20 balances swept into the hook between swaps.
- Total share supply, plus the locked `MINIMUM_SHARES` at `address(0)` (V2-style inflation defense).

## Surface

`PoolVault` exposes read-only views plus internal primitives that subclasses wrap as entry points:

- **Views:** `totalAssets(key)`, `previewDeposit(key, shares)`, `previewWithdraw(key, shares)`.
- **Internal primitives:** `_bootstrap(key, from, to, amount0, amount1)`, `_deposit(key, from, to, shares)`, `_withdraw(key, from, to, shares)`.
- **Errors:** `PoolNotBootstrapped`, `PoolAlreadyBootstrapped`, `InsufficientBootstrap`, `InsufficientShares`, `InsufficientPoolBalance`, `SameBlockWithdraw`, `VaultLiquidityShortfall`, `CrossPoolShareLeak`.

Subclasses expose user-facing entry points by wrapping the primitives (with their own access control and reentrancy guards). `SmartPoolHook` exposes `bootstrap`, `addLiquidity`, and `removeLiquidity` this way, all carrying OZ's transient `nonReentrant` guard.

## Invariants

- **Share-asset proportionality.** After any successful `addLiquidity` or `removeLiquidity`, `shares[user] / totalShares ≈ user's claim on (vault0 + claims0 + erc20_0)` and likewise for token1, subject to standard rounding.
- **Locked MINIMUM_SHARES.** Bootstrap permanently locks `MINIMUM_SHARES` at `address(0)`. These shares can never be redeemed.
- **No share inflation.** The first depositor cannot inflate share price arbitrarily because `bootstrap` mints by `sqrt(amount0 * amount1)` and locks the minimum.

# SwapSimulator

A library that replicates v4's tick-walking swap loop to produce indicative quotes and price-bounded fill plans without modifying state.

## Public functions

```solidity
library SwapSimulator {
    function simulateSwap(
        IPoolManager poolManager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 feePips,
        int24 tickSpacing
    ) internal view returns (uint256 outputAmount);

    function simulateSwapToPrice(
        IPoolManager poolManager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 feePips,
        int24 tickSpacing,
        uint160 sqrtPriceLimitX96
    ) internal view returns (uint256 amountIn, uint256 amountOut);
}
```

`simulateSwap` returns the output for an exact-input swap (or required input for exact-output) given the supplied fee. `simulateSwapToPrice` runs the same loop but terminates when the running sqrtPrice reaches `sqrtPriceLimitX96`, returning both consumed input and produced output. Both walk the pool's current tick bitmap and read live `getSlot0` / `getLiquidity` state via `StateLibrary`.

Quote-vs-execution fidelity for `simulateSwap` is exercised by the test suite across multi-range pools.

# Quoter Hook Specifications

This section specifies behavioral requirements that apply to any hook implementing `IALFHook` regardless of inheritance.

## Hook flags

All ALF quoter hooks MUST set the `beforeSwap` flag. Additional flags depend on the chosen settlement model:

| Settlement Model | Required Flags | Optional Flags |
| --- | --- | --- |
| Native LP (fee override) | `afterInitialize`, `beforeSwap` | `beforeAddLiquidity`, `beforeRemoveLiquidity` (gating) |
| JIT LP | `afterInitialize`, `beforeSwap`, `afterSwap` | `beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity` |
| Delta override | `beforeSwap`, `beforeSwapReturnDelta` | `afterSwap` |

`SimpleSpreadQuoterHook` uses Native LP; `SmartPoolHook` uses JIT LP. No delta-override quoter ships in this branch.

<a id="settlement-models"></a>
## Settlement Models

### Native LP (Fee Override)

The maker maintains persistent v4 LP positions in the quoter's pool via standard `modifyLiquidity` calls. The hook controls effective pricing by returning a **fee override** from `_beforeSwap`. The AMM executes the swap against the maker's LP; the hook itself never touches tokens.

**Requirements:**

- The pool MUST be initialized with `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`). Fee overrides are only applied for dynamic fee pools.
- `_beforeSwap` returns `(selector, ZERO_DELTA, feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG)`.
- `beforeSwapReturnDelta` MUST be `false` — the hook does not manipulate deltas.
- The hook does not need `afterSwap`.

**Reference implementation:** `SimpleSpreadQuoterHook`.

### JIT LP (Just-in-Time Liquidity)

The hook deploys liquidity in `_beforeSwap`, lets the AMM execute against it, then removes the liquidity in `_afterSwap`. Capital can come from the maker's wallet, ERC4626 vaults, or any other source the hook chooses.

**Requirements:**

- The pool MUST be initialized with `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG`.
- `_beforeSwap` deploys LP via `poolManager.modifyLiquidity()` (skipping hook callbacks via `noSelfCall`), settles the LP delta, stores per-position info in transient storage, and returns a fee override.
- `_afterSwap` removes the LP, resolves the resulting delta (typically minting ERC-6909 claims to the hook for retained inventory), and clears transient storage.
- `beforeSwapReturnDelta` MUST be `false`.
- The hook MUST use transient storage to pass position parameters between `_beforeSwap` and `_afterSwap`.

**Note on afterSwap settlement:** During `afterSwap`, the PoolManager may not yet hold sufficient ERC-20 balance to satisfy `take()` calls (the swapper's settlement occurs after the swap function returns). Hooks SHOULD use `poolManager.mint()` to issue ERC-6909 claims for the LP removal delta.

**Reference implementation:** `SmartPoolHook`.

### Delta Override

The hook directly computes and returns swap deltas from `beforeSwap`, bypassing the AMM entirely. The hook is responsible for all token settlement.

**Requirements:**

- `beforeSwapReturnDelta` MUST be `true`.
- `_beforeSwap` returns a `BeforeSwapDelta` that fully specifies the swap amounts.
- The hook MUST settle all token movements (pull input, deliver output) within the `beforeSwap` call.
- The hook MUST itself apply any v4 protocol fee — the PoolManager only enforces protocol fees against its native swap math, which is bypassed in this model.
- The pool does not require `DYNAMIC_FEE_FLAG` since the AMM is not used for pricing.

No delta-override quoter ships in this branch. The auction hook itself uses `beforeSwapReturnDelta` to forward nested-swap deltas, but it is not a quoter.

## beforeSwap requirements

1. **Execution control.** The hook controls swap execution via the chosen settlement model. For Native LP and JIT LP, the hook returns `ZERO_DELTA` and a fee override. For Delta Override, the hook returns a `BeforeSwapDelta` that fully specifies the swap amounts.
2. **Sender agnosticism.** The hook SHOULD NOT execute differently based on `sender`. The sender will typically be the router (direct routing), the auction hook (auction-mediated swaps), or end users (in which case `_resolveAttestation` decides whether they get attested pricing). All are valid callers.
3. **HookData parsing.** Hooks that consume curve updates or attestation MUST parse the standard `ALFHookData` envelope via `BaseALFHook._resolveHookData`.
4. **State updates.** The hook MAY update internal state during `_beforeSwap` (pricing coefficients, accumulators, inventory tracking, JIT lock setup, etc.). `SmartPoolHook` is the canonical example.

## hookData-based update mode

Quoters using the hookData-based update mode accept signed curve parameters via `hookData.curveUpdateData`. The standard mechanism is:

1. Caller submits hookData containing a curve update.
2. `_beforeSwap` calls `_resolveHookData`, then `_validateCurveUpdateMeta`, then `_checkAndMarkCurveUpdate`.
3. On the first matching call in the block, the subclass verifies the EIP-712 signature against `priceSigner` and commits the new state.
4. Subsequent calls in the same block must submit the same `keccak256(curveUpdateData)` or revert `ConflictingCurveUpdate`.

The first-in-block update is committed to storage and applies to all subsequent swaps in the block. Subclasses that don't accept hookData updates (e.g., `SmartPoolHook`) ignore the curve-update path entirely.

# Reference Implementations

## SimpleSpreadQuoterHook (Native LP)

A minimal `SpreadQuoterBase` subclass with owner-restricted LP and single-tick concentration.

**Settlement model:** Native LP (fee override).

**Hook flags:** `afterInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`.

**State (additional to inherited):**

```solidity
mapping(address => bool) public authorizedLPs;
```

**Behavior:**

- `_beforeAddLiquidity`: requires `authorizedLPs[sender] == true`, then enforces `tickWidth == tickSpacing` and `tickLower == activeLowerTick[poolId]`.
- `_beforeRemoveLiquidity`: requires `authorizedLPs[sender] == true`.
- `_beforeSwap`: inherits `SpreadQuoterBase` behavior (curve update + fee override).

**Owner functions (in addition to `SpreadQuoterBase`):**

- `setAuthorizedLP(address lp, bool authorized)` — toggle LP authorization.

**Use case:** baseline strategy for the auction hook test fixtures and a minimal example for makers exploring the integration path.

## SmartPoolHook (JIT LP + Rehypothecation)

JIT spread quoter with multi-range liquidity distribution and ERC4626 vault rehypothecation. Inherits `SpreadQuoterBase`, `PoolVault`, and `ReentrancyGuardTransient`.

**Settlement model:** JIT LP.

**Hook flags:** `beforeInitialize`, `afterInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`.

**Per-pool config:** owner-supplied `PoolConfig` (token vaults, bucket weights, max bucket count, tick widths) is committed via `initializePool`. The hook bounds bucket count to `MAX_BUCKETS = 8` and uses `LP_SALT = bytes32(uint256(0x534D5254)) /* "SMRT" */` to namespace its positions in the PoolManager.

**Per-pool state:** `PoolState` packs scalars (active range bookkeeping, in-flight JIT counters, vault references, etc.); `PoolVault` storage tracks share supply and per-asset balances.

**JIT lifecycle:**

```
_beforeSwap:
  1. Set the per-pool JIT lock (and increment global lock counter).
  2. Compute per-bucket liquidity from current per-pool assets and weights.
  3. Compute exact token0/token1 needed via SqrtPriceMath at the current price.
  4. Redeem outstanding ERC-6909 claims first; withdraw only the shortfall from vaults.
  5. Deploy each bucket as a concentrated v4 LP position via poolManager.modifyLiquidity (noSelfCall).
  6. Settle all incoming LP deltas; return (selector, ZERO_DELTA, feeOverride).

[pool executes the swap against the deployed LP under the fee override]

_afterSwap:
  1. Remove all bucket positions.
  2. Settle net deltas: negative → ERC-20 to PM (sweeping per-pool ERC-20 tracking),
     positive → mint ERC-6909 claims to the hook.
  3. Re-deposit any remaining per-pool ERC-20 to the vaults.
  4. Clear the per-pool JIT lock and decrement the global counter.
```

**Pricing:** owner-controlled via inherited `pricingState`. The hook **intentionally ignores** `hookData` on swaps — pricing is never updated through swap-time payloads. The signed-curve-update infrastructure inherited from `SpreadQuoterBase` is therefore dormant for `SmartPoolHook` pools. `getIndicativeQuote` and `swapToPrice` use stored pricing only.

**Slippage protection:** maker-supplied tolerance bounds applied to vault redemption and JIT execution to defuse adversarial vault behavior.

**Reentrancy:** user-facing entry points (`bootstrap`, `addLiquidity`, `removeLiquidity`) carry OZ's `nonReentrant` guard. PM-driven callbacks (`_beforeSwap`, `_afterSwap`) manage a separate per-pool transient `JIT_LOCK` and a global counter so that an owner-configured ERC4626 vault cannot reenter LP entry points mid-JIT (cross-pool path included).

**Owner functions (in addition to `SpreadQuoterBase`):**

- `initializePool(PoolKey key, PoolConfig config)` — commit initial vault references and bucket distribution before any swap or LP activity.
- `setDistribution(PoolKey key, LiquidityBucket[] buckets)` — update the per-bucket tick widths and weights.
- `setExternalDeposits(PoolKey key, bool enabled)` — toggle whether non-owner addresses can call `addLiquidity`.
- `setPoolLive(PoolKey key, bool live)` — toggle pool liveness (also syncs the PM's stored dynamic LP fee).
- `setActiveTick(PoolKey, int24)` — overridden to revert; `SmartPoolHook` derives the active tick from pool state during each JIT cycle and does not support manual override.
- All mutators are gated by `whenJITNotInProgress` to prevent reentry from an owner-configured ERC4626 vault during a swap callback.

**Use case:** primary strategy hook for the upcoming external audit. Exercises the full ALF surface — `IALFHook`, `BaseALFHook`, `SpreadQuoterBase`, `PoolVault`, `SwapSimulator`, JIT settlement under reentrancy constraints.

# ALFMultiplexer

Stateless atomic auction hook deployed on a virtual (zero-liquidity) pool. The router supplies a targeted set of quoters via `hookData` and the auction executes a greedy split fill or a router-supplied pre-planned split, applying the v4 protocol fee on the unspecified side.

## Inheritance

```solidity
contract ALFMultiplexer is BaseHook, ALFProtocolFees;
```

## Hook permissions

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: true,        // block LP on virtual pool
        beforeRemoveLiquidity: false,
        afterAddLiquidity: false,
        afterRemoveLiquidity: false,
        beforeSwap: true,                // core auction logic
        afterSwap: false,
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: true,     // forward aggregate nested-swap delta
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    });
}
```

`_beforeAddLiquidity` always reverts `LiquidityNotAllowed()`.

## hookData payload

```solidity
struct AuctionHookData {
    bytes attestationData;        // Shared across all targets, may be empty
    TargetedQuoter[] targets;     // Must be non-empty
    uint24 strictTolerancePips;   // 0 = no check; >0 = max relative deviation (ppm) per target
}

struct TargetedQuoter {
    PoolKey poolKey;              // Quoter's pool (hook address embedded in poolKey.hooks)
    bytes curveUpdateData;        // Quoter-specific signed curve update, or empty
    int256 amountSpecified;       // 0 = autonomous; nonzero = pre-planned amount for this target
}
```

The auction passes the per-target `curveUpdateData` and shared `attestationData` through to each nested swap by re-encoding them as `ALFHookData` in the order the target sees.

## Execution modes

The mode is selected implicitly by the `targets[]` array contents:

- **Autonomous mode** — every `targets[i].amountSpecified == 0`. The auction:
  1. Queries each target's `getIndicativeQuote{gas: maxGas}` (skips on revert / zero / OOG).
  2. Sorts targets by quote quality (highest output for exact-input, lowest input for exact-output).
  3. Runs the greedy split fill: for each target in sorted order, calls `poolManager.swap` on the target's pool with `sqrtPriceLimitX96` set to the next target's current pool price (or the default min/max for the last target). The v4 swap loop terminates when the marginal price worsens to the next candidate's level, naturally handing flow off.
- **Pre-planned mode** — any `targets[i].amountSpecified != 0`. The auction skips indicative queries and sorting and executes targets in supplied order using each target's `amountSpecified`. A target with `amountSpecified == 0` mops up the remainder of the swap.

In both modes, `strictTolerancePips > 0` enforces `|executed − indicative| / indicative ≤ strictTolerancePips / 1_000_000` per target; a violation reverts the entire swap.

## Protocol fee

After the split fill, the auction reads slot0's protocol fee on its own virtual pool and applies it to the unspecified delta via `poolManager.take()` to the protocol fee jar. Fees on the specified side are not separately collected (the specified amount is swap-defined).

## Delta forwarding

The auction's virtual pool has zero liquidity. The accumulated `BalanceDelta` from the nested swaps is negated into a `BeforeSwapDelta` that offsets the virtual pool's swap, so the hook's net position with the PoolManager is zero. Mapping `(amount0, amount1) → (specified, unspecified)` depends on swap direction.

## Invariants

- **No quoter state.** The hook MUST NOT maintain any per-quoter state (no participant mappings, no registration, no allowlists, etc.). The candidate set is supplied by the caller.
- **No liquidity.** The auction's virtual pool MUST NOT accept liquidity. `beforeAddLiquidity` reverts `LiquidityNotAllowed()`.
- **Hookdata-derived candidate set.** Targets MUST come from the `AuctionHookData` decoded from `hookData`.
- **Staticcall isolation for indicatives.** All `getIndicativeQuote` calls MUST be made via `staticcall` (implicit because the function is `view`). Targets cannot observe each other's indicative quotes or modify state during the quoting round.
- **Soft fail per quoter.** A failing target (revert, zero quote, OOG) MUST NOT abort the entire auction in autonomous mode; it is skipped.
- **Hard fail on no quotes.** If autonomous mode produces no valid candidate, the hook reverts `NoValidQuotes`.
- **Direction-aware comparison.** For exact-input swaps, the highest output wins. For exact-output swaps, the lowest required input wins.
- **Tolerance binding.** When `strictTolerancePips > 0`, every target that fills MUST satisfy the per-target deviation bound or the entire swap reverts.

## Call flow

```
Router → poolManager.swap(auctionPool)
  → AuctionHook._beforeSwap()
    → [staticcall] target_i.getIndicativeQuote()  // autonomous mode only
    → [for each target in fill order]
        poolManager.swap(target.poolKey)
          → target.beforeSwap()
          ← BalanceDelta_i
    → poolManager.take(unspecifiedToken, FEE_JAR, protocolFeeAmount)
  ← BeforeSwapDelta (negated aggregate)
← BalanceDelta
```

This call pattern is explicitly supported by v4 and mirrors multi-hop swap routing. Correctness requires that the negated `BeforeSwapDelta` matches the aggregate of the nested-swap `BalanceDelta`s plus the protocol fee taken — incorrect forwarding causes `CurrencyNotSettled` at unlock.

# Router Integration Specification

The router is an offchain system. This section specifies the interface between the router and the onchain components.

## Discovery

The router maintains its own internal registry of known ALF hooks, populated through:

- **Onchain event monitoring:** pool creation events, hook deployment events.
- **Manual registration:** API endpoints for makers to register their hooks.
- **Partner integrations:** direct hook address exchange during onboarding.

For each known hook, the router queries `IALFHook` methods directly (`isLive()`, `maxGas()`, `getIndicativeQuote()`, `swapToPrice()`). The router SHOULD cache liveness and gas data and refresh periodically (recommended: ≤ 1 block on the target chain).

## Indicative quoting

For each candidate the router considers:

```solidity
output = IALFHook(hook).getIndicativeQuote{gas: maxGas}(
    poolKey, zeroForOne, amountSpecified, hookData
);
```

This call MUST be a `staticcall`. The router MUST respect the quoter's declared `maxGas`. `hookData` is the standard `ALFHookData` envelope, with `attestationData` populated when the swap originates from an attested source.

## Reputation model

The router MUST maintain a reputation model per quoter, tracking:

- **Quote fidelity:** rolling mean of `(actualOutput − indicatedOutput) / indicatedOutput`.
- **Fill rate:** rolling mean of `successfulSwaps / attemptedSwaps`. Quoters with `fillRate < threshold` (recommended: 0.95) are deprioritized.
- **Revert tracking:** consecutive `_beforeSwap` reverts trigger temporary or extended exclusion.
- **Gas accuracy:** rolling mean of `actualGas / declaredMaxGas`. Quoters that consistently OOG are penalized.

For routing decisions:

```solidity
adjustedOutput = indicatedOutput × (1 + fidelity[quoter]) − gasCost;
```

## Dispatch strategy

- **Candidate selection:** filter known hooks by `isLive() == true` and reputation thresholds.
- **EV-based ordering:** sort by `adjustedOutput`.
- **Marginal EV cutoff:** stop calling additional candidates when the marginal expected improvement falls below the gas cost of the call.
- **Explore budget:** reserve a configurable fraction of swaps (recommended 5-10%) for unproven quoters to maintain model freshness.
- **Vanilla fallback:** always include at least one vanilla v4 pool (if one exists) in the candidate set as the baseline.

## Auction hook routing

The router MAY route through `ALFMultiplexer` instead of routing directly. The decision is a routing-level concern based on:

- **Quoter count for the pair.** If small (≤ 5), the auction's exhaustive comparison is affordable.
- **Swap size.** Larger swaps benefit more from fairness guarantees.
- **Chain characteristics.** On chains with adversarial sequencers or high MEV, the auction's atomicity is more valuable.
- **Router confidence.** If the router's reputation model is well-calibrated for a pair, direct routing is preferred. If the model is uncertain, the auction provides a safer default.

When routing through the auction hook, the router submits a swap to the auction's virtual pool with an `AuctionHookData` payload encoding the candidate set and (optionally) a pre-planned split.

# Cross-cutting Concerns

## Token Accounting

Token accounting depends on the settlement model:

**Native LP model (`SimpleSpreadQuoterHook`):**
- The maker holds v4 LP positions in the quoter's pool. The AMM handles all token accounting during swaps. The hook itself never touches tokens.

**JIT LP model (`SmartPoolHook`):**
- Per-pool inventory is tracked across three buckets: ERC4626 vault shares, ERC-6909 claims held in the PoolManager, and per-pool ERC-20 balances swept into the hook between cycles.
- In `_beforeSwap`, the hook adds LP via `poolManager.modifyLiquidity()` (skipping hook callbacks via `noSelfCall`). Claims are redeemed first, then vault shortfalls are withdrawn, then per-pool ERC-20 covers the rest. LP deltas are settled via `_settle()`.
- In `_afterSwap`, the hook removes LP. Negative deltas are paid in ERC-20 from the per-pool sweep (debiting the tracker); positive deltas mint ERC-6909 claims to the hook for the next cycle. **`_take()` is NOT used in `_afterSwap`** — the PoolManager may not hold sufficient ERC-20 balance at that point.
- LP-account share math is handled by `PoolVault` (see [PoolVault](#poolvault)).

**Auction hook (delta forwarding):**
- The auction's virtual pool holds no liquidity. All token movement happens through nested `poolManager.swap` calls on the candidates' real pools. The auction's only direct PM interaction is `poolManager.take()` for the protocol fee.

## Pool Initialization

Each quoter hook requires a pool to be initialized in the PoolManager:

```solidity
poolManager.initialize(poolKey, sqrtPriceX96);
```

**Dynamic fee requirement:** Quoter hooks using the Native LP or JIT LP settlement models MUST initialize their pool with `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`). The fee override mechanism in `Hooks.sol` only parses the fee return value from `beforeSwap` when the pool's fee is dynamic. Pools initialized with a static fee will silently ignore the hook's fee override.

The auction hook's virtual pool does NOT require `DYNAMIC_FEE_FLAG` — it uses delta override, not fee override. It can be initialized with `fee: 0` and `tickSpacing: 1`.

`SmartPoolHook` follows up on `_afterInitialize` with its own `initializePool(key, PoolConfig)` call to commit vault references and bucket configuration before any swap or LP activity. Until that runs, swaps on a SmartPoolHook pool see `state.live == false` and execute at the pool's stored fee.

Quoter hooks SHOULD use the `afterInitialize` callback for any initialization logic (e.g., setting `activeLowerTick` for LP positioning).

## Upgradeability

- **Quoter hooks:** Immutable per deployment. Quoters upgrade by deploying a new hook, notifying the router, and migrating liquidity. The router's reputation model starts fresh for the new hook.
- **Auction hook:** Immutable. New versions are deployed independently.
- **Configuration mutability:** Owner-managed parameters (`pricingState`, `priceSigner`, `authorizedLPs`, `PoolConfig`, bucket weights) are mutable through owner-gated functions. Curve updates from `priceSigner` are mutable per-block via the signed-update path.

## Governance

| Parameter | Controlled By | Mechanism |
| --- | --- | --- |
| Per-quoter pricing state | Hook owner | `SpreadQuoterBase.updatePricingState`, signed `priceSigner` updates |
| Per-quoter `priceSigner` | Hook owner | `SpreadQuoterBase.setPriceSigner` |
| LP authorization (`SimpleSpreadQuoterHook`) | Hook owner | `setAuthorizedLP` |
| `SmartPoolHook` config (vaults, weights) | Hook owner | `initializePool`, weight mutators |
| v4 protocol fee on quoter pools | v4 governance | Standard v4 protocol fee path (collected by PoolManager during swap) |
| v4 protocol fee on auction-routed swaps | v4 governance | `ALFProtocolFees` reads slot0 and forwards to the protocol fee jar |
| Router dispatch parameters | Router operator | Offchain configuration |
| Hook blocklist | Router operator | Offchain configuration; handled by router reputation model |

There is no governance-managed allowlist of quoters or attesters at the protocol level — both are per-maker decisions.

## Error Conditions

| Condition | Component | Behavior |
| --- | --- | --- |
| Quoter `getIndicativeQuote` reverts | Router / Auction Hook | Quoter is skipped for this swap. Router records revert for reputation. |
| Quoter `getIndicativeQuote` exceeds `maxGas` | Router / Auction Hook | Call fails due to gas limit. Same as revert. |
| Quoter `getIndicativeQuote` returns 0 | Router / Auction Hook | Quoter is skipped (treated as unable to price). |
| Quoter `_beforeSwap` reverts after being selected | Router | Swap fails. Router retries with next-best candidate. Records revert for reputation. |
| Auction autonomous mode produces no valid quote | Auction Hook | `_beforeSwap` reverts with `NoValidQuotes()`. |
| Auction tolerance violated for any target | Auction Hook | Entire swap reverts. |
| Liquidity added to auction's virtual pool | Auction Hook | `_beforeAddLiquidity` reverts with `LiquidityNotAllowed()`. |
| No known quoters for pair | Router | Pair is routed through non-ALF pools only. |
| Conflicting curve update in same block | `BaseALFHook` | `_checkAndMarkCurveUpdate` reverts `ConflictingCurveUpdate`. |
| Curve update past deadline | `BaseALFHook` | `_validateCurveUpdateMeta` reverts `ExpiredUpdate`. |
| Curve update for wrong pool | `BaseALFHook` | `_validateCurveUpdateMeta` reverts `PoolMismatch`. |
| Invalid `priceSigner` signature | `SpreadQuoterBase` | `_verifySignature` reverts `InvalidPriceSigner`. |
| Pricing state with `bidFeePips` or `askFeePips` > `MAX_LP_FEE` | `SpreadQuoterBase` | `_validateFeeBounds` reverts `FeeOutOfBounds`. |
| LP add/remove on `SmartPoolHook` mid-JIT | `SmartPoolHook` | Per-pool/global JIT lock rejects entry; `whenJITNotInProgress` modifier reverts. |
| Quoter pool initialized without `DYNAMIC_FEE_FLAG` | Native/JIT LP quoter | Fee override silently ignored; swaps execute at the pool's stored static fee. |
| Unauthorized LP on `SimpleSpreadQuoterHook` | `SimpleSpreadQuoterHook` | `_beforeAddLiquidity` / `_beforeRemoveLiquidity` reverts `UnauthorizedLP`. |
| Wrong active tick on `SimpleSpreadQuoterHook` | `SimpleSpreadQuoterHook` | `_enforceActiveTick` reverts `WrongActiveTick` or `InvalidTickRange`. |

## Gas Estimates

| Operation | Estimated Gas | Notes |
| --- | --- | --- |
| `IALFHook.isLive` | ~2,500–5,000 | Simple view call |
| `IALFHook.maxGas` | ~2,500 | Immutable read |
| `IALFHook.getIndicativeQuote` (`SpreadQuoterBase`) | ~30,000–150,000 | Tick-walking simulation depends on range crossed |
| `IALFHook.swapToPrice` (`SpreadQuoterBase`) | ~30,000–200,000 | Same loop with price-bounded termination |
| `SmartPoolHook` JIT cycle (single bucket) | ~250,000–350,000 | beforeSwap + LP deploy + afterSwap + redistribute |
| `SmartPoolHook` JIT cycle (multi-bucket, e.g. 3) | ~400,000–600,000 | Linear in bucket count |
| `ALFMultiplexer.beforeSwap` (autonomous, 5 targets) | ~500,000–900,000 | 5× indicative + sort + greedy fill across winners |
| `ALFMultiplexer.beforeSwap` (pre-planned, 2 targets) | ~250,000–400,000 | Skips indicatives + sorting |

These are rough estimates intended only for sizing and routing decisions. Actual gas varies with the underlying strategy hooks (fee/liquidity range, vault implementations) and tick-bitmap depth on the swap path.
