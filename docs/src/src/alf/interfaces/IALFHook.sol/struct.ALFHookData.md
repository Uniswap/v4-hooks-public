# ALFHookData
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0c68c6912ec9b3df692fd62740997db52f245b7d/src/alf/interfaces/IALFHook.sol)

Standard hookData encoding for ALF hooks.

Callers MUST encode hookData as `abi.encode(ALFHookData(...))`.
`attestationData` is optional — pass empty bytes when not applicable.


```solidity
struct ALFHookData {
bytes attestationData; // ABI-encoded attestation payload, or empty
}
```

