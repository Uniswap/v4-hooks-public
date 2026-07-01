# ALFHookData
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/interfaces/IALFHook.sol)

Standard hookData encoding for ALF hooks.

Callers MUST encode hookData as `abi.encode(ALFHookData(...))`.
`attestationData` is optional; pass empty bytes when not applicable.


```solidity
struct ALFHookData {
bytes attestationData; // ABI-encoded attestation payload, or empty
}
```

