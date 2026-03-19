# ALF: Formal Specification

**Version:** 0.2.0-draft
**Authors:** Uniswap Labs Protocols Team
**Status:** Draft
**Last Updated:** February 2026

---

# Overview

This document species the interfaces, contracts, behaviors and invariants of the ALF system. It is intended as an implementation reference. For motivation, rationale and product context, see [ALF: Composable Quoter Model](https://www.notion.so/ALF-Composable-Quoter-Model-30cc52b2548b80518c92c3ae4a0e10fa?pvs=21).

## System Components

| Component | Type | Mutability | Deployment |
| --- | --- | --- | --- |
| `IAttestationRegistry` | Interface | — | — |
| `AttestationRegistry` | Contract | State: attester whitelist | One per chain |
| `IALFHook` | Interface | — | — |
| `BaseALFHook` | Abstract contract | — | Extended by quoters |
| `StorageQuoterHook` | Contract (reference) | State: per-pool pricing config | One per quoter per pair |
| `Permit2JITQuoterHook` | Contract (reference) | State: per-pool JIT config | One per quoter per pair |
| Quoter hooks (custom) | Contracts | State: per-quoter pricing | One per quoter per pair |
| `ALFAuctionHook` | Contract | Stateless | One per chain |

## Dependencies

- Uniswap v4 PoolManager
- Uniswap v4 BaseHook
- Uniswap v4 DeltaResolver (via v4-periphery)
- Uniswap v4 core types (`PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `BeforeSwapDelta`)
- Permit2 `IAllowanceTransfer` (for JIT quoter)

## Conventions

- `PoolId` is derived from `PoolKey` via `PoolKey.toId()`.
- "Pair" refers to an unordered `(Currency, Currency)` tuple. "Pool" refers to a specific `PoolKey` which includes the pair, fee, tick spacing, and hook address.
- Gas values are specified as `uint32`, supporting up to ~4.29 billion gas units. This should be more than sufficient for all current use cases and future-proof for the foreseeable future of typical EVMs.
- All view functions called for quoting purposes MUST be invoked via `staticcall`.

# AttestationRegistry

The AttestationRegistry manages attestation keys and verifies flow attestations. It is read by quoter hooks to determine whether a swap originates from an attested source (e.g., the Uniswap frontend or TAPI). It does not enforce how quoters use attestation data. Additionally, this registry is not intended to serve as an exclusive authority list; individual quoters may choose to ignore, augment or fully rely on this registry to make informed decisions about attestation validity.

## **Types**

```solidity
struct Attestation {
    address attester;    // The attesting interface
    address swapper;     // The user initiating the swap
    uint256 deadline;    // Attestation expiry timestamp
    bytes32 swapHash;    // keccak256(abi.encode(currency0, currency1, zeroForOne, amountSpecified))
}
```

## Interface

```solidity
interface IAttestationRegistry {
    // ──── Events ────

    event AttesterAdded(address indexed attester);
    event AttesterRemoved(address indexed attester);

    // ──── Mutations (Governance controlled) ────

    /// @notice Add an authorized attester.
    /// @dev MUST be restricted to governance.
    /// @dev MUST emit AttesterAdded.
    /// @dev MUST revert if attester is already authorized.
    function addAttester(address attester) external;

    /// @notice Remove an authorized attester.
    /// @dev MUST be restricted to governance.
    /// @dev MUST emit AttesterRemoved.
    /// @dev MUST revert if attester is not authorized.
    function removeAttester(address attester) external;

    // ──── Views ────

    /// @notice Verify an attestation signature.
    /// @dev MUST NOT revert on invalid attestation. Returns isValid = false instead.
    /// @dev MUST return isValid = false if:
    ///      - The signature is invalid
    ///      - The recovered attester is not authorized
    ///      - block.timestamp > attestation.deadline
    /// @dev MUST NOT check swapHash (this is the caller's responsibility).
    /// @param attestationData ABI-encoded (Attestation, bytes signature).
    /// @return attestation The parsed attestation struct.
    /// @return isValid Whether the attestation is valid.
    function verify(
        bytes calldata attestationData
    ) external view returns (Attestation memory attestation, bool isValid);

    /// @notice Check if an address is an authorized attester.
    function isAuthorizedAttester(address attester) external view returns (bool);
}
```

## Attestation Format

```solidity
attestationData = abi.encode(
    Attestation({
        attester: <attester address>,
        swapper: <user address>,
        deadline: <block.timestamp expiry>,
        swapHash: keccak256(abi.encode(currency0, currency1, zeroForOne, amountSpecified))
    }),
    <bytes signature>
)
```

The signature is an EIP-712 typed signature over the `Attestation` struct, signed by the attester's private key.

## Invariants

- **Non-reverting.** `verify()` MUST NOT revert regardless of input. Malformed input MUST return `isValid = false`.
- **No state mutation.** `verify()` is a view function. No state changes occur during attestation verification.
- **Time-bounded.** Attestations with `deadline < block.timestamp` MUST return `isValid = false`; `deadline >= block.timestamp` with a valid signature MUST return `isValid = true`
- **Attester authorization.** Attestations signed by non-authorized attesters MUST return `isValid = false`.
- **swapHash is caller-verified.** The registry verifies the signature and expiry but does NOT verify that the `swapHash` matches the current swap parameters. The calling hook SHOULD perform this check if it wants to bind the attestation to specific swap parameters.

## EIP-712 Domain

<aside>
🚧

**Note:** The EIP-712 domain and type hash are preliminary. Final specification pending study of Jupiter's attestation model and feedback from stakeholders.

</aside>

```solidity
EIP712Domain({
    name: "Attestation",
    version: "1",
    chainId: block.chainid,
    verifyingContract: <AttestationRegistry address>
})
```

**Type Hash:**

```solidity
bytes32 constant ATTESTATION_TYPEHASH = keccak256(
    "Attestation(address attester,address swapper,uint256 deadline,bytes32 swapHash)"
);
```

# IALFHook

A standard interface implemented by ALF hooks on top of the v4 hook interface. Provides a uniform way for the router and auction hook to query indicative quotes from any quoter.

## Interface

```solidity
interface IALFHook {
    /// @notice Get an indicative quote for routing purposes.
    /// @dev MUST be a view function. Callers invoke via staticcall.
    /// @dev MUST NOT revert under normal conditions. If the quoter cannot
    ///      price the requested swap, it SHOULD return 0.
    /// @dev The returned value is non-binding. The actual execution price
    ///      is determined by the hook's beforeSwap implementation.
    /// @param key The pool key for this quoter's pool.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified The swap amount. Negative = exact input.
    /// @param attestationData ABI-encoded attestation payload, or empty bytes
    ///        if no attestation is available.
    /// @return outputAmount The indicative number of output tokens.
    ///         For exact input swaps, this is the expected output.
    ///         For exact output swaps, this is the required input.
    function getIndicativeQuote(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata attestationData
    ) external view returns (uint256 outputAmount);

    /// @notice Whether this quoter is currently live and accepting swaps.
    /// @dev Quoters SHOULD return true if the current curve is not stale.
    /// @dev Consumers SHOULD validate against observed behavior.
    function isLive() external view returns (bool);

    /// @notice The declared maximum gas for getIndicativeQuote execution.
    /// @dev Callers use this to set gas limits on staticcall invocations.
    /// @dev Quoters that exceed their declared maxGas will have their
    ///      getIndicativeQuote calls fail, resulting in router deprioritization.
    function maxGas() external view returns (uint32);
}
```

## Behavioral Requirements

- **View-only.** `getIndicativeQuote` MUST be callable via `staticcall`. It MUST NOT modify state.
- **Non-reverting.** `getIndicativeQuote` SHOULD NOT revert. If the quoter cannot price a swap (insufficient liquidity, unsupported direction, etc.), it SHOULD return `0`. Quoters that revert will be deprioritized by the router's reputation model.
- **Gas-bounded.** `getIndicativeQuote` MUST execute within the gas limit declared by `maxGas()`. Consumers will call with `{gas: maxGas}` and treat OOG conditions as a failure.
- **Attestation handling.** If `attestationData` is empty, the quoter MUST return a quote for unattested flow. If `attestationData` is non-empty, the quoter MAY offer preferential pricing. The quoter is responsible for calling `AttestationRegistry.verify()` if it wants to validate the attestation (this is automatically handled by the abstract `BaseALFHook`).
- **Consistency.** The indicative quote SHOULD be consistent with the price that `beforeSwap` would produce given the same parameters in the same block. Persistent divergence between indicative and executed prices will cause router deprioritization. (See PRD: Quote Fidelity & Reputation Model.)

# BaseALFHook

An abstract base contract that quoter hooks MAY extend. Provides attestation resolution, the `IALFHook` implementation (with sensible defaults for `getReserves` and `getEffectiveLiquidity`), and delta settlement helpers via `DeltaResolver`. Quoters extend this and implement `_price()` with their proprietary pricing logic. Use is encouraged but not required.

## Inheritance

`BaseALFHook` inherits from both `BaseHook` and `DeltaResolver`. This dual-inheritance pattern (mirroring `BaseTokenWrapperHook` in v4-periphery) gives quoter hooks access to `_settle()` and `_take()` for delta resolution during swap lifecycle hooks.

The `_pay()` function required by `DeltaResolver` is implemented to transfer tokens directly to the PoolManager:

```solidity
function _pay(Currency token, address, uint256 amount) internal override {
    token.transfer(address(poolManager), amount);
}
```

## Abstract Interface

```solidity
abstract contract BaseALFHook is BaseHook, DeltaResolver, IALFHook {
    IAttestationRegistry public immutable attestationRegistry;
    uint32 private immutable _maxGas;

    constructor(
        IPoolManager _poolManager,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_
    ) BaseHook(_poolManager) {
        attestationRegistry = _attestationRegistry;
        _maxGas = maxGas_;
    }

    // ──── IALFHook ────

    function maxGas() external view override returns (uint32) {
        return _maxGas;
    }

    function getIndicativeQuote(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    ) external view virtual override returns (uint256 outputAmount) {
        bytes memory attestationData;
        if (hookData.length > 0) {
            ALFHookData memory hd = abi.decode(hookData, (ALFHookData));
            attestationData = hd.attestationData;
        }
        (bool isAttested, address attester) = _resolveAttestation(attestationData);
        return _price(key, zeroForOne, amountSpecified, isAttested, attester);
    }

    function isLive() external view virtual override returns (bool);

    /// @dev Default returns (0, 0). Override for hooks with off-pool reserves.
    function getReserves(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @dev Default returns (0, 0). Override for hooks with off-pool reserves.
    function getEffectiveLiquidity(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    // ──── Internal: Attestation ────

    /// @dev Parse and verify attestation from raw bytes.
    /// @return isAttested Whether a valid attestation was provided.
    /// @return attester The attester address (zero if not attested).
    function _resolveAttestation(
        bytes memory attestationData
    ) internal view returns (bool isAttested, address attester) {
        if (attestationData.length == 0) return (false, address(0));
        (Attestation memory att, bool valid) =
            attestationRegistry.verify(attestationData);
        return (valid, valid ? att.attester : address(0));
    }

    // ──── Abstract: Pricing ────

    /// @dev Subclasses MUST implement pricing logic.
    /// @param key The pool key.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified The swap amount. Negative = exact input.
    /// @param isAttested Whether the swap has a valid attestation.
    /// @param attester The attester address (zero if not attested).
    /// @return outputAmount The quoted output.
    function _price(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bool isAttested,
        address attester
    ) internal view virtual returns (uint256 outputAmount);
}
```

## Implementation Requirements

Implementations MUST:

- Implement `_price()` with their proprietary pricing logic.
- Implement `isLive()` from `IALFHook`.
- Implement `_beforeSwap()` to control execution behavior. The implementation depends on the chosen settlement model (see [Settlement Models](#settlement-models)).

Implementations SHOULD:

- Ensure that the output of `_price()` is approximately consistent with the actual swap output for the same parameters. Divergence degrades the quoter's reputation score.
- Override `getReserves()` and `getEffectiveLiquidity()` if the hook manages off-pool reserves (e.g., rehypothecation, vault-backed liquidity).
- Verify `swapHash` in `beforeSwap` if using attestation-dependent pricing, since the `AttestationRegistry` does not perform this check.

# Quoter Hook Specifications

This section specifies behavioral requirements for quoter hooks regardless of whether they extend `BaseALFHook`.

## Hook Flags

All ALF quoter hooks MUST set the `beforeSwap` flag. Additional flags depend on the chosen settlement model:

| Settlement Model | Required Flags | Optional Flags |
| --- | --- | --- |
| Native LP (fee override) | `afterInitialize`, `beforeSwap` | — |
| JIT LP | `afterInitialize`, `beforeSwap`, `afterSwap` | — |
| Delta override | `beforeSwap`, `beforeSwapReturnDelta` | `afterSwap` |

All other flags (`beforeAddLiquidity`, `afterRemoveLiquidity`, `beforeDonate`, etc.) are OPTIONAL and at the quoter's discretion.

<a id="settlement-models"></a>
## Settlement Models

Quoter hooks can use one of three settlement models for swap execution. All three are compatible with the `IALFHook` interface and the auction hook. The choice of settlement model is orthogonal to the update mode (storage-based, hookData-based, external).

### Native LP (Fee Override)

The maker maintains persistent v4 LP positions in the quoter's pool via standard `modifyLiquidity` calls. The hook controls effective pricing by returning a **fee override** from `_beforeSwap`. The AMM executes the swap against the maker's LP; the hook itself never touches tokens.

**Requirements:**

- The pool MUST be initialized with `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`). Fee overrides are only applied for dynamic fee pools (see `Hooks.sol:263`).
- `_beforeSwap` returns `(selector, ZERO_DELTA, feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG)`.
- `beforeSwapReturnDelta` MUST be `false` — the hook does not manipulate deltas.
- The hook does not need `afterSwap`.

**Tradeoffs:** Simplest model. The hook is stateless during swap execution. Pricing granularity is limited to the fee override mechanism (pips precision). Actual execution price depends on LP distribution and pool state.

**Reference implementation:** `StorageQuoterHook`

### JIT LP (Just-in-Time Liquidity)

The hook pulls tokens from the maker's wallet (via Permit2 or other mechanism), adds concentrated LP in `beforeSwap`, lets the AMM execute against it, then removes the LP in `afterSwap` and returns tokens to the maker.

**Requirements:**

- The pool MUST be initialized with `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG`.
- `_beforeSwap` adds LP via `poolManager.modifyLiquidity()` (skips hook callbacks via `noSelfCall`), settles the LP delta, stores position info in transient storage, and returns a fee override.
- `_afterSwap` removes the LP, resolves the resulting delta (typically via `poolManager.mint()` to issue ERC-6909 claims to the maker), and clears transient storage.
- `beforeSwapReturnDelta` MUST be `false`.
- The hook MUST use transient storage (Cancun EVM) to pass position parameters between `beforeSwap` and `afterSwap`.

**Note on afterSwap settlement:** During `afterSwap`, the PoolManager may not yet hold sufficient ERC-20 balance to satisfy `take()` calls (the swapper's settlement occurs after the swap function returns). Hooks MUST use `poolManager.mint()` to issue ERC-6909 claims to the maker instead of `_take()` for the LP removal delta.

**Tradeoffs:** More complex but allows zero standing liquidity — maker capital is only deployed for the duration of a single swap. Combines fee override pricing with JIT capital efficiency.

**Reference implementation:** `Permit2JITQuoterHook`

### Delta Override

The hook directly computes and returns swap deltas from `beforeSwap`, bypassing the AMM entirely. The hook is responsible for all token settlement.

**Requirements:**

- `beforeSwapReturnDelta` MUST be `true`.
- `_beforeSwap` returns a `BeforeSwapDelta` that fully specifies the swap amounts.
- The hook MUST settle all token movements (pull input, deliver output) within the `beforeSwap` call.
- The pool does not require `DYNAMIC_FEE_FLAG` since the AMM is not used for pricing.

**Tradeoffs:** Maximum pricing flexibility — the hook has full control over exact amounts. More complex to implement correctly (delta accounting, settlement). The pool's native CPMM state is unused.

**Note:** This was the only settlement model in spec v0.1. It remains valid for quoters that need full control over swap amounts, but the native LP and JIT LP models are preferred for most use cases as they leverage v4's native AMM execution.

## beforeSwap Specification

```solidity
function beforeSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata hookData
) external override returns (bytes4, BeforeSwapDelta, uint24);
```

**Requirements:**

1. **Execution control.** The hook controls swap execution via the chosen settlement model. For native LP and JIT LP models, the hook returns `ZERO_DELTA` and a fee override. For the delta override model, the hook returns a `BeforeSwapDelta` that fully specifies the swap amounts.
2. **Sender agnosticism.** The hook SHOULD NOT execute differently based on `sender`. The sender will typically be either the router (for direct routing) or the auction hook (for pure onchain routing). Both are valid callers.
3. **Attestation parsing.** If the hook supports preferential pricing for attested flow, it MUST parse attestation data from `hookData`. The format is [described above](https://www.notion.so/ALF-Formal-Spec-311c52b2548b80589834cd397c8f6ab7?pvs=21).
4. **State updates.** The hook MAY update internal state (pricing coefficients, accumulators, inventory tracking) during `beforeSwap`. This is the designated state mutation point.

## hookData-based Update Mode

Quoters using the hookData-based update mode accept signed curve parameters via `hookData`. The following constraints apply:

### One Update Per Block

```solidity
mapping(PoolId => mapping(uint256 => bytes32)) internal blockCurveHash;
```

- On the first swap in a block for a given `PoolId`, the hook SHOULD verify the curve signature, cache the curve hash at `blockCurveHash[poolId][block.number]`, and store the curve parameters.
- On subsequent swaps in the same block for the same `PoolId`, the hook MAY require that the submitted curve hash matches the cached hash. If it does not match, the hook MAY revert.

### Signature Verification

Curve updates MUST be signed by an authorized key for the quoter. The authorization mechanism is quoter-specific (e.g., an owner-controlled key registry within the hook). This is distinct from the flow attestation validation.

### hookData encoding for hookData-based quoters

When both attestation data and curve parameters are present in `hookData`, e.g.:

```solidity
hookData = abi.encode(
    bytes attestationData,      // Attestation payload (may be empty)
    bytes curveUpdateData       // ABI-encoded (CurveParams, bytes signature)
)
```

The hook MUST handle the case where `attestationData` is empty (no attestation) ***and*** the case where `curveUpdateData` is empty (use cached/stored curve).

## External ALF Wrapper Hooks

Wrapper hooks that wrap external ALF contracts MUST:

- Implement `IALFHook`.
- In `beforeSwap`, call the external ALF's swap function and translate the result into a `BeforeSwapDelta`.
- Perform an **invariant check** after the external swap: verify that the output received matches the expected output within an acceptable tolerance.
- If the external swap fails or the invariant check fails, the hook MUST revert.
- Implement `getIndicativeQuote` by reading the external ALF's quote function (if available) or by simulating the swap.

Wrapper hooks MAY impose a Uniswap governance-controlled fee configuration which MAY be used by the router to prioritize governance-aligned wrappers of external ALFs.

# Reference Implementations

## StorageQuoterHook (Native LP)

A storage-based quoter using the native LP settlement model. The maker maintains persistent v4 LP positions in the quoter's pool. The hook controls effective pricing via fee overrides and provides coefficient-based indicative quotes.

**Settlement model:** Native LP (fee override)

**Hook flags:** `afterInitialize`, `beforeSwap`

**State:**

```solidity
struct PricingState {
    uint128 bidCoefficient;     // Indicative quote coefficient for zeroForOne (1e18 scaled)
    uint128 askCoefficient;     // Indicative quote coefficient for oneForZero (1e18 scaled)
    uint24 bidFeePips;          // Fee override for zeroForOne swaps (pips, max 1_000_000)
    uint24 askFeePips;          // Fee override for oneForZero swaps (pips, max 1_000_000)
    uint16 attestedDiscountBps; // Discount for attested flow in indicative quotes (bps)
    bool live;
}
mapping(PoolId => PricingState) public pricingState;
```

**`_beforeSwap` behavior:**

1. If not live, returns `(selector, ZERO_DELTA, 0)` — no fee override, swap executes at default fee.
2. Otherwise, returns `(selector, ZERO_DELTA, feePips | OVERRIDE_FEE_FLAG)` where `feePips` is `bidFeePips` or `askFeePips` depending on direction.

**`_price` behavior:** Returns `(|amountSpecified| × coefficient) / 1e18`, with an additional multiplicative discount of `(10000 + attestedDiscountBps) / 10000` for attested flow.

**Owner functions:** `updatePricingState(key, state)`, `setPoolLive(key, live)`.

## Permit2JITQuoterHook (JIT LP)

A JIT liquidity quoter using the JIT LP settlement model. Pulls tokens from a maker's wallet via Permit2 `IAllowanceTransfer`, adds concentrated LP in `beforeSwap`, lets the AMM execute against it, then removes the LP in `afterSwap` and returns tokens to the maker as ERC-6909 claims.

**Settlement model:** JIT LP

**Hook flags:** `afterInitialize`, `beforeSwap`, `afterSwap`

**State:**

```solidity
struct JITConfig {
    address maker;              // Wallet holding capital (has Permit2 approval → this hook)
    uint128 bidCoefficient;     // Indicative quote coefficient for zeroForOne (1e18)
    uint128 askCoefficient;     // Indicative quote coefficient for oneForZero (1e18)
    uint24 bidFeePips;          // Fee override for zeroForOne swaps
    uint24 askFeePips;          // Fee override for oneForZero swaps
    int24 tickWidth;            // Half-width for JIT LP range (in ticks, before alignment)
    uint128 liquidity;          // Liquidity units to add per swap
    uint16 attestedDiscountBps; // Discount for attested indicative quotes
    bool live;
}
mapping(PoolId => JITConfig) public jitConfig;
```

**Transient storage:** The hook uses Cancun EVM transient storage (`tstore`/`tload`) to pass JIT position parameters (tickLower, tickUpper, liquidity) between `beforeSwap` and `afterSwap`.

**`_beforeSwap` behavior:**

1. If not live or liquidity is zero, returns `(selector, ZERO_DELTA, 0)`.
2. Reads current tick via `StateLibrary.getSlot0()`.
3. Computes tick range centered on current tick, aligned to `tickSpacing`.
4. Adds LP via `poolManager.modifyLiquidity()` (callbacks skipped via `noSelfCall`).
5. Pulls exact delta amounts from maker via `permit2.transferFrom()` and settles to PM.
6. Stores position in transient storage.
7. Returns `(selector, ZERO_DELTA, feePips | OVERRIDE_FEE_FLAG)`.

**`_afterSwap` behavior:**

1. Loads JIT position from transient storage. If no position, returns early.
2. Removes LP via `poolManager.modifyLiquidity()` with negative `liquidityDelta`.
3. Mints ERC-6909 claims to the maker for the resulting positive delta (NOT `take()`).
4. Clears transient storage.

**Maker setup:**

1. Maker approves ERC-20 tokens to the Permit2 contract.
2. Maker grants Permit2 allowance to the hook contract via `permit2.approve(token, hook, amount, expiration)`.

**Owner functions:** `updateJITConfig(key, config)`, `setPoolLive(key, live)`.

# ALFAuctionHook

The ALFAuctionHook provides atomic onchain competitive quoting as a routing strategy. It is a stateless v4 hook deployed on a virtual (i.e., zero-liquidity) pool. The router chooses whether to route through the auction hook on a per-swap basis. Quoters SHOULD be agnostic to the use of the auction hook.

<aside>
🚧

It is imperative that individual quoter hooks are deployed to a CREATE2 mined address which encodes the correct flags. This is an inherited v4 constraint. See the [Hook Deployment](https://docs.uniswap.org/contracts/v4/guides/hooks/hook-deployment) section of the v4 docs for context.

</aside>

## Properties

- **Stateless.** The auction hook holds no quoter-specific state. The quoter set is provided by the router via `hookData`.
- **Transparent to quoters.** The winning quoter's `beforeSwap` is invoked via a nested `poolManager.swap`. The quoter's hook cannot distinguish between a direct router swap and an auction-mediated swap (except by inspecting `sender`, which is discouraged but not explicitly disallowed).
- **Targeted comparison.** The auction hook queries all quoters provided in the `hookData`. The router controls the candidate set using its reputation model.
- **Atomic.** The indicative quoting round, winner selection, and execution all occur within a single `beforeSwap` invocation.

## Interface

```solidity
contract ALFAuctionHook is BaseHook {
    error NoValidQuotes();
    error LiquidityNotAllowed();

    event AuctionExecuted(
        address indexed winner,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 bestQuote
    );

    /// @dev Hook flags: beforeAddLiquidity (block LP), beforeSwap, beforeSwapReturnsDelta
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,  // block liquidity on virtual pool
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,          // core auction logic
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // forward winner's delta
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(...) internal pure override returns (bytes4) {
        revert LiquidityNotAllowed();
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // 1. Run auction: discover quoters and pick the best
        (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote) =
            _runAuction(key.currency0, key.currency1, params, hookData);

        // 2. Execute nested swap on winner's pool (with unlimited price limit)
        BalanceDelta nestedDelta = poolManager.swap(
            winnerPoolKey,
            SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );

        // 3. Convert BalanceDelta → BeforeSwapDelta
        //    Negate to offset the hook's nested delta against the outer pool.
        //    Mapping (amount0, amount1) → (specified, unspecified) depends on direction.
        BeforeSwapDelta bsd = _toBeforeSwapDelta(nestedDelta, params);

        emit AuctionExecuted(winner, params.zeroForOne, params.amountSpecified, bestQuote);

        return (IHooks.beforeSwap.selector, bsd, 0);
    }

    /// @dev Query targeted quoters from hookData, return the best one.
    ///      For exact input: highest output wins.
    ///      For exact output: lowest required input wins.
    function _runAuction(
        SwapParams calldata params,
        bytes calldata hookData
    ) internal view returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote) {
        TargetedQuoter[] memory targets = abi.decode(hookData, (TargetedQuoter[]));
        bool isExactInput = params.amountSpecified < 0;
        bool foundValid;

        for (uint256 i = 0; i < targets.length; i++) {
            address hook = targets[i].poolKey.hooks;
            try IALFHook(hook).isLive() returns (bool live) {
                if (!live) continue;
            } catch { continue; }

            uint32 gas = IALFHook(hook).maxGas();

            try IALFHook(hook).getIndicativeQuote{gas: gas}(
                targets[i].poolKey, params.zeroForOne, params.amountSpecified, targets[i].hookData
            ) returns (uint256 quote) {
                if (quote == 0) continue;

                bool isBetter = !foundValid
                    || (isExactInput ? quote > bestQuote : quote < bestQuote);

                if (isBetter) {
                    bestQuote = quote;
                    winnerPoolKey = targets[i].poolKey;
                    winner = hook;
                    foundValid = true;
                }
            } catch {}
        }

        if (!foundValid) revert NoValidQuotes();
    }

    /// @dev Negate the nested swap's BalanceDelta into a BeforeSwapDelta.
    function _toBeforeSwapDelta(BalanceDelta nestedDelta, SwapParams calldata params)
        internal pure returns (BeforeSwapDelta)
    {
        bool isExactInput = params.amountSpecified < 0;
        int128 specified;
        int128 unspecified;

        if (isExactInput == params.zeroForOne) {
            specified = -nestedDelta.amount0();
            unspecified = -nestedDelta.amount1();
        } else {
            specified = -nestedDelta.amount1();
            unspecified = -nestedDelta.amount0();
        }

        return toBeforeSwapDelta(specified, unspecified);
    }
}
```

**Note on `sqrtPriceLimitX96`:** The auction hook passes `MIN_SQRT_PRICE + 1` (zeroForOne) or `MAX_SQRT_PRICE - 1` (oneForZero) as the price limit for the nested swap, rather than forwarding the caller's limit. This ensures the nested swap executes fully against the winner's pool. The outer pool's price limit (if any) is enforced by the PoolManager on the auction pool's virtual swap.

## Invariants

- **No quoter state.** The auction hook MUST NOT maintain any per-quoter state (no participant mappings, no registration, no allowlists, etc.).
- **No liquidity.** The auction hook's virtual pool MUST NOT accept liquidity. `beforeAddLiquidity` reverts with `LiquidityNotAllowed()`.
- **Hookdata-derived.** The quoter set MUST be derived from the `TargetedQuoter[]` provided in `hookData`.
- **Staticcall isolation.** All `getIndicativeQuote` calls MUST be made via `staticcall` (implicitly enforced by the function being `view`). Quoters cannot observe each other's indicative quotes or modify state during the quoting round.
- **Soft fail per quoter.** A failing quoter MUST NOT cause the entire auction to revert. Failed `getIndicativeQuote` calls are caught and the quoter is skipped. Zero-value quotes are also skipped.
- **Hard fail on zero quotes.** If no quoter returns a valid quote, the auction hook MUST revert with `NoValidQuotes()`.
- **Direction-aware comparison.** For exact input swaps, the highest output wins. For exact output swaps, the lowest required input wins.

## Call Flow

The auction hook performs a nested `poolManager.swap()` from within its own `beforeSwap()`. This creates the following call stack:

```solidity
Router → poolManager.swap(auctionPool)
  → AuctionHook.beforeSwap()
    → [staticcall] QuoterHook.getIndicativeQuote()  (× N quoters)
    → poolManager.swap(winnerPool)
      → WinnerHook.beforeSwap()
      ← BalanceDelta
    ← BalanceDelta
  ← BeforeSwapDelta
← BalanceDelta
```

This is explicitly allowed by v4 and closely mirrors the standard pattern for multi-hop swaps. The only correctness requirement is that the `BeforeSwapDelta` returned by the auction hook for its virtual pool must accurately reflect the `BalanceDelta` produced by the winning quoter's pool. All deltas accumulate in transient storage during the unlock and must net to zero before `lock()` is called. Incorrect delta forwarding will cause the transaction to revert with `CurrencyNotSettled`.

# Router Integration Specification

The router is an offchain system. This section specifies the interface between the router and the onchain components.

## Discovery

The router maintains its own internal registry of known ALF hooks, populated through:

- **Onchain event monitoring:** Pool creation events, hook deployment events.
- **Manual registration:** API endpoints for makers to register their hooks.
- **Partner integrations:** Direct hook address exchange during onboarding.

For each known hook, the router queries `IALFHook` methods directly (`isLive()`, `maxGas()`, `getIndicativeQuote()`). The router SHOULD cache liveness and gas data and refresh periodically (recommended: ≤ 1 block on the target chain).

## Indicative Quoting

For each quoter the router considers, it calls:

```solidity
output = IALFHook(hook).getIndicativeQuote{gas: maxGas}(
		poolKey,
		zeroForOne,
		amountSpecified,
		attestationData
)
```

This call MUST be a `staticcall`. The router MUST respect the quoter's declared `maxGas`.

## Reputation Model

The router MUST maintain a reputation model for each quoter. The model tracks the following metrics:

### Quote Fidelity

```solidity
fidelity[quoter] = rollingMean(
    (actualOutput - indicatedOutput) / indicatedOutput
)
```

Computed over a rolling window (implementation-defined, recommended: last 100 fills or 24 hours, whichever is larger).

**Usage:** The router computes a fidelity-adjusted output for routing decisions:

```solidity
adjustedOutput = indicatedOutput × (1 + fidelity[quoter]) - gasCost
```

The router SHOULD consider this fidelity in comparing indicatives among competing quoters. For example, a quoter with fidelity = -0.002 (implying it consistently delivers 0.2% less at execution than indicated) has its indicative discounted by 0.2%.

### **Fill Rate**

```solidity
fillRate[quoter] = rollingMean(successfulSwaps / attemptedSwaps)
```

Quoters with `fillRate < threshold` (implementation-defined, recommended: 0.95) are deprioritized.

### **Revert Tracking**

Each `beforeSwap` revert after the router routes to a quoter is recorded. Quoters with persistent reverts are excluded from routing after a configurable number of consecutive failures (recommended: 3 consecutive reverts triggers temporary exclusion; 10 in a rolling window triggers extended exclusion).

### Gas Accuracy

```solidity
gasAccuracy[quoter] = rollingMean(actualGas / declaredMaxGas)
```

Quoters that consistently use gas close to their declared maximum are appropriately priced. Quoters that significantly underestimate (as observed by OOG failures) are penalized.

## Dispatch Strategy

The router MUST implement the following dispatch logic:

- **Candidate selection.** From the known hook set, select quoters where `isLive() == true` and further filter based on reputation model (e.g., `fillRate > exclusionThreshold` and other factors that may place the quoter in a temporary exclusion state).
- **EV-based ordering.** Order candidates by `adjustedOutput` (fidelity-adjusted indicative minus gas cost).
- **Marginal EV cutoff.** Stop calling additional quoters when the marginal expected improvement from the next quoter is less than the gas cost of the call.
- **Explore budget.** Reserve a configurable fraction of swaps (recommended: 5-10%) for calling quoters outside the top-N, including new quoters with no history, to maintain model freshness.
- **Fallback inclusion.** Always include at least one vanilla v4 pool (if one exists for the pair) in the candidate set.

## Auction Hook Routing

The router MAY route through the auction hook instead of routing directly. The decision is a pure routing-level concern based on:

- **Quoter count for the pair.** If the quoter count is small (≤ 5), the auction hook's exhaustive comparison is affordable.
- **Swap size.** Larger swaps benefit more from fairness guarantees.
- **Chain characteristics.** On chains with adversarial sequencers or high MEV, the auction hook's atomicity is more valuable.
- **Router confidence.** If the router's reputation model is well-calibrated for a pair, direct routing is preferred. If the model is uncertain (new pair, new quoters), the auction hook provides a safer default.

When routing through the auction hook, the router submits a swap to the auction hook's virtual pool. The auction hook handles quoter selection and execution.

# Cross-cutting Concerns

## Token Accounting

All native (i.e., not wrapped external) ALF quoter hooks SHOULD operate within v4's singleton PoolManager. Token accounting depends on the settlement model:

**Native LP model:**
- The maker holds v4 LP positions in the quoter's pool. The AMM handles all token accounting during swaps. The hook itself never touches tokens.

**JIT LP model:**
- In `beforeSwap`, the hook adds LP via `poolManager.modifyLiquidity()` (which skips hook callbacks via `noSelfCall`). The LP delta is settled by pulling tokens from the maker (e.g., via Permit2) and calling `_settle()`.
- In `afterSwap`, the hook removes LP. The resulting positive delta is resolved via `poolManager.mint()` to issue ERC-6909 claims to the maker. **Important:** `_take()` MUST NOT be used in `afterSwap` because the PoolManager may not hold sufficient ERC-20 balance at that point (the swapper's settlement occurs after the swap function returns).
- Makers can redeem ERC-6909 claims to ERC-20 via `poolManager.burn()` in a separate transaction.

**Delta override model:**
- The hook's `beforeSwap` returns a `BeforeSwapDelta` that specifies the exact token amounts.
- The PoolManager settles balances via `take()` and `settle()` within the `unlock` context.
- Quoter hooks that hold liquidity within the PoolManager (as claims) interact via `mint()` and `burn()`.
- Quoter hooks that hold liquidity externally MUST inject sufficient liquidity during settlement.

## Pool Initialization

Each quoter hook requires a pool to be initialized in the PoolManager:

```solidity
poolManager.initialize(poolKey, sqrtPriceX96, hookData);
```

**Dynamic fee requirement:** Quoter hooks using the native LP or JIT LP settlement models MUST initialize their pool with `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`). This is required because the fee override mechanism in `Hooks.sol` only parses the fee return value from `beforeSwap` when the pool's fee is dynamic (`key.fee.isDynamicFee()`). Pools initialized with a static fee will silently ignore the hook's fee override.

The auction hook's virtual pool does NOT require `DYNAMIC_FEE_FLAG` (it uses delta override, not fee override). It can be initialized with `fee: 0` and `tickSpacing: 1`.

The `sqrtPriceX96` and tick spacing are quoter-defined. For native LP and JIT LP models, the pool's CPMM state is used for swap execution, so the initial price and tick spacing are meaningful. For the delta override model, the pool's native pricing is bypassed.

Quoter hooks SHOULD use the `afterInitialize` callback for any initialization logic (e.g., setting active tick for LP positioning).

## Upgradeability

- **AttestationRegistry:** Governance-upgradeable (attester whitelist only). The verification logic is immutable.
- **Quoter hooks:** Immutable per deployment. Quoters upgrade by deploying a new hook, notifying the router, and migrating liquidity. The router's reputation model starts fresh for the new hook.
- **Auction hook:** Immutable. New versions are deployed independently.

## Governance

| Parameter | Controlled By | Mechanism |
| --- | --- | --- |
| Attester whitelist | Governance | `AttestationRegistry.addAttester/removeAttester` |
| Internal ALF fees | Governance | Handled indirectly via v4 fee config (likely the default fee) |
| External ALF fees | Governance | Wrapper hook parameter |
| Router dispatch parameters | Router operator | Offchain configuration |
| Hook blocklist | Router operator | Offchain configuration; handled by router reputation model |

## Error Conditions

| Condition | Component | Behavior |
| --- | --- | --- |
| Quoter `getIndicativeQuote` reverts | Router / Auction Hook | Quoter is skipped for this swap. Router records revert for reputation. |
| Quoter `getIndicativeQuote` exceeds `maxGas` | Router / Auction Hook | Call fails due to gas limit. Same as revert. |
| Quoter `getIndicativeQuote` returns 0 | Router / Auction Hook | Quoter is skipped (treated as unable to price). |
| Quoter `beforeSwap` reverts after being selected | Router | Swap fails. Router retries with next-best candidate. Records revert for reputation. |
| No quoters return valid quotes (auction hook) | Auction Hook | `beforeSwap` reverts with `NoValidQuotes()`. |
| Liquidity added to auction hook's virtual pool | Auction Hook | `beforeAddLiquidity` reverts with `LiquidityNotAllowed()`. |
| No known quoters for pair | Router | Pair is routed through non-ALF pools only. |
| Attestation is invalid or expired | Quoter Hook | Quoter prices swap as unattested flow. No revert. |
| Conflicting curve update in same block | hookData-based quoter | `beforeSwap` reverts. |
| JIT LP hook calls `take()` in `afterSwap` | JIT Quoter Hook | ERC-20 underflow. MUST use `poolManager.mint()` instead. |
| Quoter pool initialized without `DYNAMIC_FEE_FLAG` | Fee override quoter | Fee override silently ignored; swaps execute at default fee. |

## Gas Estimates

| Operation | Estimated Gas | Notes |
| --- | --- | --- |
| `IALFHook.getIndicativeQuote` | ~5,000–100,000 | Depends on curve complexity |
| `IALFHook.isLive` | ~2,500–5,000 | Simple view call |
| `IALFHook.maxGas` | ~2,500 | Immutable read |
| `ALFAuctionHook.beforeSwap` (5 quoters) | ~50,000–700,000 | 5× (isLive + maxGas + indicative) + 1× swap |
| Direct routing: single quoter swap | ~100,000–200,000 | Standard v4 swap with hook |
| `AttestationRegistry.verify` | ~5,000–10,000 | ECDSA recovery + storage read |

Note that these are very rough estimates intended only for reasoning. Actual gas will vary based on quoter implementation and various optimization efforts.