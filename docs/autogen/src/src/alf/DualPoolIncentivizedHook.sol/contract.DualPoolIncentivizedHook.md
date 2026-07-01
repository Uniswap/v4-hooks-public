# DualPoolIncentivizedHook
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/DualPoolIncentivizedHook.sol)

**Inherits:**
[DualPoolHook](/src/alf/DualPoolHook.sol/contract.DualPoolHook.md)

**Title:**
DualPoolIncentivizedHook

**Author:**
Uniswap Labs

`DualPoolHook` composed with the `Rewards` liquidity-incentives capability. LP shares
earn a third reward token via Synthetix-style per-block accrual on the `BlockNumberish`
clock, on top of the JIT spread quoting and ERC-4626 rehypothecation inherited unchanged
from `DualPoolHook`.
The composition adds no new v4 hook callback, so the permission flags (and the
address-mining requirement) are identical to `DualPoolHook`; it does not touch the
swap path; and it reuses the base's share ledger. The `Rewards` capability is held as a
plain storage field (`_rewards`), and its behavior is invoked on it directly via
type-driven free functions, as `_rewards.checkpoint(...)`. It wires
`PoolVault._onShareCheckpoint` (which fires on bootstrap, deposit, and withdraw, before
the share counts move) to `Rewards.checkpoint`, so accrual settles when LP positions
change.
## Trust model
Adds one capability to the operator surface: funding rewards. The owner binds a reward
token ([setRewardToken](/src/alf/DualPoolIncentivizedHook.sol/contract.DualPoolIncentivizedHook.md#setrewardtoken), permanent), sets the period cadence ([setRewardsDuration](/src/alf/DualPoolIncentivizedHook.sol/contract.DualPoolIncentivizedHook.md#setrewardsduration)),
and funds periods ([notifyRewardAmount](/src/alf/DualPoolIncentivizedHook.sol/contract.DualPoolIncentivizedHook.md#notifyrewardamount), pulling the reward token from the caller). The
reward token MUST NOT be either pool currency, so reward custody never aliases the
pool's ERC-20 inventory tracked by `InventoryLib`. The owner cannot touch accrued LP
rewards; only the earning LP can [claimRewards](/src/alf/DualPoolIncentivizedHook.sol/contract.DualPoolIncentivizedHook.md#claimrewards).

**Note:**
security-contact: security@uniswap.org


## State Variables
### _rewards
Liquidity-incentives capability storage: a Synthetix reward program per pool vault.


```solidity
Rewards internal _rewards
```


## Functions
### constructor


```solidity
constructor(IPoolManager pm, uint32 maxGas_, address owner_, uint64 maxMinDepositBlocks_)
    DualPoolHook(pm, maxGas_, owner_, maxMinDepositBlocks_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`pm`|`IPoolManager`|                 The Uniswap v4 PoolManager.|
|`maxGas_`|`uint32`|            Gas budget declared for `getIndicativeQuote` staticcalls.|
|`owner_`|`address`|             Initial owner (see {OwnedALFHook}).|
|`maxMinDepositBlocks_`|`uint64`|Per-deployment upper bound on `PoolConfig.minDepositBlocks`.|


### _onShareCheckpoint

Settle reward accrual on the pre-mutation balances. Overrides the `PoolVault`
checkpoint seam; fires on bootstrap, deposit, and withdraw, never on swaps.


```solidity
function _onShareCheckpoint(VaultId vaultId, address user, uint256 totalSharesBefore, uint256 userSharesBefore)
    internal
    override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|          The vault whose shares are about to change.|
|`user`|`address`|             The account whose share balance is about to change.|
|`totalSharesBefore`|`uint256`|Total shares outstanding immediately before the mutation.|
|`userSharesBefore`|`uint256`| `user`'s share balance immediately before the mutation.|


### setRewardToken

Bind the reward token for a pool. Permanent (accrued balances must resolve against
one token). Rejects either pool currency.


```solidity
function setRewardToken(PoolKey calldata key, IERC20 token) external onlyOwner whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|  The pool to configure.|
|`token`|`IERC20`|The reward ERC-20.|


### setRewardsDuration

Set the reward period length for a pool. Only permitted between periods.


```solidity
function setRewardsDuration(PoolKey calldata key, uint256 duration) external onlyOwner whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|     The pool to configure.|
|`duration`|`uint256`|Period length in blocks (on the `BlockNumberish` clock).|


### notifyRewardAmount

Fund a reward period for a pool (or top up the active one). Pulls `reward` of the
configured reward token from the caller, then recomputes the per-block rate.


```solidity
function notifyRewardAmount(PoolKey calldata key, uint256 reward)
    external
    onlyOwner
    nonReentrant
    whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|   The pool to fund.|
|`reward`|`uint256`|Reward tokens to add to the period.|


### claimRewards

Claim accrued reward tokens for the caller on a pool.

`whenJITNotInProgress` is conservative gating: a claim only touches the non-pool reward
token and the `Rewards` ledger, never the JIT-managed pool currencies. Since the claim
makes an external `safeTransfer`, the blanket JIT guard is the simplest safe choice. The
cost is that a claim reverts while any pool's swap is mid-flight, a minor liveness
coupling rather than a safety issue.


```solidity
function claimRewards(PoolKey calldata key) external nonReentrant whenJITNotInProgress returns (uint256 amount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool to claim from.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Reward tokens transferred to the caller.|


### earned

Reward tokens `user` could claim right now on a pool.


```solidity
function earned(PoolKey calldata key, address user) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`| The pool to read.|
|`user`|`address`|The account to query.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The claimable reward amount.|


## Errors
### RewardTokenNotConfigured
`notifyRewardAmount` was called before a reward token was bound via [setRewardToken](/src/alf/DualPoolIncentivizedHook.sol/contract.DualPoolIncentivizedHook.md#setrewardtoken).


```solidity
error RewardTokenNotConfigured();
```

### RewardTokenIsPoolCurrency
`setRewardToken` was given one of the pool's own currencies. The reward token must be
distinct so reward custody never aliases `InventoryLib`'s per-pool ERC-20 ledger.


```solidity
error RewardTokenIsPoolCurrency();
```

