# ALFHookData
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/510f5fe7d91535158cac5795bb284c347ddb8126/src/alf/interfaces/IALFHook.sol)

Standard hookData encoding for ALF hooks.

Callers MUST encode hookData as `abi.encode(ALFHookData(...))`.
`attestationData` is optional — pass empty bytes when not applicable.


```solidity
struct ALFHookData {
bytes attestationData; // ABI-encoded attestation payload, or empty
}
```

