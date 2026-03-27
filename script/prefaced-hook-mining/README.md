# Prefaced hook address mining

Uniswap v4 hook contracts must deploy to an address whose **low 14 bits** encode which hook callbacks are used (`Hooks` permission flags). [`HookMiner`](../src/utils/HookMiner.sol) searches CREATE2 salts until those bits match and the target address has no code.

**PrefacedHookMiner** adds an **additional constraint**: the **most significant byte** of the 20-byte address (the first byte you see in `0x**AB**cd…`) must equal a chosen value. That makes hits much rarer than plain `HookMiner`, so this repo also ships a **Forge script** and a **bash loop** that retries over successive salt ranges. This additional byte can by used by routing teams to infer false-positive-tolerable informtation easily, such as external liquidity protocol the hook links to, or routing eschewal altogether.

Allowlist Declination byte: 0x91

NOTE: The allowlist declination byte should is used as the preface of a hook address to signal to the routing team to not include a hook in the production allowlist. 

## Components

| Piece | Role |
|--------|------|
| [`src/utils/PrefacedHookMiner.sol`](../src/utils/PrefacedHookMiner.sol) | Library: `find(deployer, flags, creationCode, constructorArgs, addressPrefix, saltStart)` over `[saltStart, saltStart + MAX_LOOP)`. |
| [`script/MinePrefacedHook.s.sol`](MinePrefacedHook.s.sol) | `MinePrefacedHookScript.run(bytes,bytes,uint256,uint8,uint160,address)` — logs predicted address and salt; does **not** broadcast. |
| [`script/minePrefacedHook.sh`](minePrefacedHook.sh) | Calls `forge script` in a loop, bumping the salt lower bound by `MAX_LOOP` after each failed window. |

`MAX_LOOP` is `160_444` in both [`HookMiner`](../src/utils/HookMiner.sol) and `PrefacedHookMiner`. The bash script hardcodes the same number; if you change it in Solidity, update the script.

## What gets checked

For each candidate salt, CREATE2 is applied to `abi.encodePacked(creationCode, constructorArgs)` (same packing as `HookMiner`). A salt is accepted only if:

1. `uint8(uint160(address) >> 152) == addressPrefix`
2. `(uint160(address) & FLAG_MASK) == (flags & FLAG_MASK)` (hook permissions bits)
3. `address.code.length == 0` on the chain where you run the script (local simulation is usually empty)

## Bash helper: `minePrefacedHook.sh`

Run from the **repository root** (the script `cd`s there).

```text
./script/minePrefacedHook.sh <prefix_byte> <creation_code> <constructor_args> [salt_start] [flags_hex] [deployer]
```

### Arguments

- **`prefix_byte`** — Required leading address byte: decimal (`66`) or hex (`0x42`).
- **`creation_code`** — Either a **path to a file** or **inline hex** (`0x…` optional). Must be **creation bytecode only** (what `type(MyHook).creationCode` is), not including constructor arguments.
- **`constructor_args`** — File path or inline hex: **ABI-encoded constructor arguments**. Use **`-`** for empty.
- **`salt_start`** — Optional; default `0`. Each failed run adds `MAX_LOOP` and retries.
- **`flags_hex`** — Optional `uint160` hook flags; default `0xac0` (before/after swap, before add/remove liquidity — same combination the old example script used). Derive the correct mask from your hook’s permissions and [`Hooks`](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol) flag constants.
- **`deployer`** — Optional. Default `0x0000000000000000000000000000000000000000` means the script uses the canonical CREATE2 deployer proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

### Files: hex text vs raw binary

If the path points to a file whose contents are **only hex** (with optional `0x` and whitespace), that hex is used. Otherwise the file is read as **raw bytes** and hex-encoded (for `.bin`-style artifacts).

For **large** bytecode, prefer a **file path** so you do not hit shell argument-length limits.

### Examples

Encode constructor arguments and mine (example pool manager address — replace with yours):

```bash
cast abi-encode "constructor(address)" 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 > /tmp/my-hook.ctor.hex
./script/minePrefacedHook.sh 0x42 out/MyHook.sol/MyHook.bytecode /tmp/my-hook.ctor.hex
```

No constructor arguments:

```bash
./script/minePrefacedHook.sh 0x00 path/to/MyHook.bytecode -
```

Custom flags and explicit deployer (zero address still selects the CREATE2 proxy inside the script):

```bash
./script/minePrefacedHook.sh 66 ./bytecode.bin - 0 0x3f3 0x0000000000000000000000000000000000000000
```

## Calling the Forge script directly

One salt window only: `[saltStart, saltStart + MAX_LOOP)`. On revert, increase `saltStart` by `MAX_LOOP` and run again (what the bash script automates).

```bash
forge script script/MinePrefacedHook.s.sol:MinePrefacedHookScript \
  --sig "run(bytes,bytes,uint256,uint8,uint160,address)" \
  <creation_hex> <ctor_args_hex> <salt_start> <prefix_u8> <flags_hex> <deployer>
```

Example with empty constructor args and defaulting deployer via zero address:

```bash
forge script script/MinePrefacedHook.s.sol:MinePrefacedHookScript \
  --sig "run(bytes,bytes,uint256,uint8,uint160,address)" \
  0x6080… 0x 0 66 0xac0 0x0000000000000000000000000000000000000000
```

## After mining

The script prints **`hookAddress`** and **`salt`** (as `bytes32`). Deploy with the same **`deployer`**, **`creationCode`**, **`constructorArgs`** you used for mining, as well as the printed **`salt`** (for example `new MyHook{salt: salt}(…)` via CREATE2 through the proxy, matching your production flow).

If any of deployer, bytecode, or constructor arguments differ from the mining inputs, the deployed address will not match the logged prediction.

## Using the library in Solidity

### Use at your own risk: simulation can run out of gas

Import `PrefacedHookMiner` and call `find` from tests or custom scripts, same as `HookMiner.find` but with `addressPrefix` and `saltStart`. For searches longer than one window, advance `saltStart` by `PrefacedHookMiner.MAX_LOOP` until a salt is found or you stop manually.
