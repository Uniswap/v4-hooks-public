# ALFHookData
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0a317c27dcab11b55acb839bccd006c6ffa8744c/src/alf/interfaces/IALFHook.sol)

Standard hookData encoding for ALF hooks.

Callers MUST encode hookData as `abi.encode(ALFHookData(...))`.
`attestationData` is optional — pass empty bytes when not applicable.


```solidity
struct ALFHookData {
bytes attestationData; // ABI-encoded attestation payload, or empty
}
```

