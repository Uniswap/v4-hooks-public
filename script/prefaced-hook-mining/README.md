# Prefaced hook address mining

Uniswap v4 hook contracts must deploy to an address whose **low 14 bits** encode which hook callbacks are used (`Hooks` permission flags). [`HookMiner`](../../src/utils/HookMiner.sol) searches CREATE2 salts until those bits match and the target address has no code.

**PrefacedHookMiner** adds an **additional constraint**: the **most significant byte** of the 20-byte address (the first byte you see in `0x**AB**cd…`) must equal a chosen value. That makes hits much rarer than plain `HookMiner`, so this repo also ships a **Forge script** and a **bash driver** that retries over successive salt ranges. That byte can be used by routing teams for coarse labeling (for example which external system the hook relates to) or to signal routing behavior.

**Allowlist declination byte:** `0x91`

The allowlist declination byte is used as the address prefix to signal that a hook should not be included in the production allowlist.

## Components

| Piece                                                                      | Role                                                                                                                                    |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| [`src/utils/PrefacedHookMiner.sol`](../../src/utils/PrefacedHookMiner.sol) | Library: `find(deployer, flags, creationCode, constructorArgs, addressPrefix, saltStart)` over `[saltStart, saltStart + MAX_LOOP)`.     |
| [`MinePrefacedHook.s.sol`](MinePrefacedHook.s.sol)                         | `MinePrefacedHookScript.run(bytes,bytes,uint256,uint8,uint160,address)` — logs predicted address and salt; does **not** broadcast.      |
| [`minePrefacedHook.sh`](minePrefacedHook.sh)                               | Runs multiple `forge script` workers in parallel per round, then advances the salt base by `MAX_LOOP × workers` until a match is found. |

`MAX_LOOP` is `160_444` in both [`HookMiner`](../../src/utils/HookMiner.sol) and `PrefacedHookMiner`. The bash script hardcodes the same number; if you change it in Solidity, update the script.

## What gets checked

For each candidate salt, CREATE2 is applied to `abi.encodePacked(creationCode, constructorArgs)` (same packing as `HookMiner`). A salt is accepted only if:

1. `uint8(uint160(address) >> 152) == addressPrefix`
2. `(uint160(address) & FLAG_MASK) == (flags & FLAG_MASK)` (hook permissions bits)
3. `address.code.length == 0` on the chain where you run the script (local simulation is usually empty)

## Bash helper: `minePrefacedHook.sh`

Run from the **repository root** (the script `cd`s there).

```text
./script/prefaced-hook-mining/minePrefacedHook.sh [options] <prefix_byte> <creation_code> <constructor_args> [flags_hex] [deployer] [salt_start]
```

### Options (CLI only)

| Option                             | Meaning                                                                                                              |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `--workers N` or `--workers=N`     | Number of parallel `forge script` processes per round (default: CPU count via `nproc` / `sysctl hw.ncpu`, else `4`). |
| `--gas-limit N` or `--gas-limit=N` | Passed through to `forge script --gas-limit` (default: `30000000000`).                                               |
| `--verbose`                        | Adds `-vvvv` to `forge script`.                                                                                      |
| `-h`, `--help`                     | Print usage.                                                                                                         |

Each worker searches a disjoint window of length `MAX_LOOP`. After a round where **no** worker finds a salt, the next round starts at `salt_start + MAX_LOOP × workers` (and keeps advancing the same way). Success prints that worker’s logs and exits.

### Positional arguments

- **`prefix_byte`** — Required leading address byte: decimal (`66`) or hex (`0x42`).
- **`creation_code`** — **Path to a file** or **inline hex** (`0x…` optional). Must be **creation bytecode only** (what `type(MyHook).creationCode` is), not including constructor arguments.
- **`constructor_args`** — File path or inline hex: **ABI-encoded constructor arguments**. Use **`-`** for none.
- **`flags_hex`** — Optional `uint160` hook flags; default `0xac0` (before/after swap, before add/remove liquidity). Must match your hook’s [`Hooks`](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol) permissions.
- **`deployer`** — Optional. Default `0x0000000000000000000000000000000000000000` means the Forge script uses the canonical CREATE2 deployer proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
- **`salt_start`** — Optional; default `0`. The script advances the base salt automatically after each failed round. To set only `salt_start` while keeping default flags and deployer, pass them explicitly, e.g. `0xac0 0x0000000000000000000000000000000000000000 20000000`.

### Files: hex text vs raw binary

If the path points to a file whose contents are **only hex** (with optional `0x` and whitespace), that hex is used. Otherwise the file is read as **raw bytes** and hex-encoded (for `.bin`-style artifacts).

For **large** bytecode, prefer a **file path** so you do not hit shell argument-length limits.

## Example: `MockCounterHook`

The repo includes [`test/mocks/MockCounterHook.sol`](../../test/mocks/MockCounterHook.sol): a small `BaseHook` that counts swap / liquidity callbacks. Its permissions match the script’s default flags **`0xac0`** (before/after swap, before add/remove liquidity).

From the **repository root**:

**1. Compile**

```bash
forge build --contracts test/mocks/MockCounterHook.sol
```

**2. Creation bytecode (pick one)**

Write hex to a file (easy to pass to the script):

```bash
forge inspect MockCounterHook bytecode | tr -d '\n' > /tmp/MockCounterHook.creation.hex
```

Or read it from the build artifact (same bytes as `forge inspect`):

```bash
jq -r '.bytecode.object' foundry-out/MockCounterHook.sol/MockCounterHook.json | tr -d '\n' > /tmp/MockCounterHook.creation.hex
```

**3. Constructor arguments**

The constructor is `constructor(IPoolManager _poolManager)`. Encode a pool manager address (use a real address for production; here we use a placeholder):

```bash
cast abi-encode "constructor(address)" 0x0000000000000000000000000000000000000001 > /tmp/MockCounterHook.ctor.hex
```

**4. Mine** (example prefix `0x42`; mining can take many rounds — use `--workers` to use more CPUs)

```bash
./script/prefaced-hook-mining/minePrefacedHook.sh \
  --workers=8 \
  0x42 \
  /tmp/MockCounterHook.creation.hex \
  /tmp/MockCounterHook.ctor.hex
```

Omit `--workers` to default to your machine’s CPU count. Add `--verbose` if you want full forge traces.

### Other examples

Encode constructor arguments and mine (replace pool manager and paths):

```bash
cast abi-encode "constructor(address)" 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 > /tmp/my-hook.ctor.hex
./script/prefaced-hook-mining/minePrefacedHook.sh --workers=4 0x42 out/MyHook.sol/MyHook.bytecode /tmp/my-hook.ctor.hex
```

No constructor arguments:

```bash
./script/prefaced-hook-mining/minePrefacedHook.sh 0x00 path/to/MyHook.bytecode -
```

Custom flags and explicit deployer (zero address still selects the CREATE2 proxy inside the Forge script), starting salt `0`:

```bash
./script/prefaced-hook-mining/minePrefacedHook.sh --workers=4 66 ./bytecode.bin - 0x3f3 0x0000000000000000000000000000000000000000 0
```

## Calling the Forge script directly

One salt window only: `[saltStart, saltStart + MAX_LOOP)`. On revert, increase `saltStart` by `MAX_LOOP` and run again (the bash script automates this across workers and rounds).

```bash
forge script script/prefaced-hook-mining/MinePrefacedHook.s.sol:MinePrefacedHookScript \
  --sig "run(bytes,bytes,uint256,uint8,uint160,address)" \
  --gas-limit 30000000000 \
  <creation_hex> <ctor_args_hex> <salt_start> <prefix_u8> <flags_hex> <deployer>
```

Example with empty constructor args and defaulting deployer via zero address:

```bash
forge script script/prefaced-hook-mining/MinePrefacedHook.s.sol:MinePrefacedHookScript \
  --sig "run(bytes,bytes,uint256,uint8,uint160,address)" \
  --gas-limit 30000000000 \
  0x6080… 0x 0 66 0xac0 0x0000000000000000000000000000000000000000
```

## After mining

The script prints **`hookAddress`** and **`salt`** (as `bytes32`). Deploy with the same **`deployer`**, **`creationCode`**, **`constructorArgs`** you used for mining, as well as the printed **`salt`** (for example `new MyHook{salt: salt}(…)` via CREATE2 through the proxy, matching your production flow).

If any of deployer, bytecode, or constructor arguments differ from the mining inputs, the deployed address will not match the logged prediction.

## Using the library in Solidity

### Use at your own risk: simulation can run out of gas

Import `PrefacedHookMiner` and call `find` from tests or custom scripts, same as `HookMiner.find` but with `addressPrefix` and `saltStart`. For searches longer than one window, advance `saltStart` by `PrefacedHookMiner.MAX_LOOP` until a salt is found or you stop manually.
