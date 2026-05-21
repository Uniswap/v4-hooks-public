# ALFHookData
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/fb38bd58a3855b38f1e6e41a9ca471e83744f2b7/src/alf/interfaces/IALFHook.sol)

Standard hookData encoding for ALF hooks.

Callers MUST encode hookData as `abi.encode(ALFHookData(...))`.
`attestationData` is optional — pass empty bytes when not applicable.


```solidity
struct ALFHookData {
bytes attestationData; // ABI-encoded attestation payload, or empty
}
```

