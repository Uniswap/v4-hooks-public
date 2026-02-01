#!/bin/bash
set -e

HOOK=0x122771c9AA343E4d35a794258aA32fE463c46088
POOL_ID=0xcf5687fc01cf2a20c6596c2cc7176b44039e8aa66bec9783b63a7527f2a15557
TOKEN0=0x8977049D59bb942b82Ed4BeC47E60ba1ADF1dCf0
TOKEN1=0x8aD2892E8B91A0832b50CfBF2c7DBe6E9875025a
TEMPO_EXCHANGE=0x469c9e7A307bde9d7A7a4199b722A8a7da291cE6
RPC="https://rpc.moderato.tempo.xyz"

echo "=== TESTING TEMPO EXCHANGE AGGREGATOR HOOK ==="
echo ""

echo "1. Testing pseudoTotalValueLocked..."
cast call $HOOK "pseudoTotalValueLocked(bytes32)(uint256,uint256)" $POOL_ID --rpc-url $RPC
echo ""

echo "2. Testing quote for exact input (1000 tokens)..."
AMOUNT_IN=-1000000000  # -1000 * 10^6 (negative for exact input)
cast call $HOOK "quote(bool,int256,bytes32)(uint256)" true $AMOUNT_IN $POOL_ID --rpc-url $RPC
echo ""

echo "3. Testing quote for exact output (500 tokens)..."
AMOUNT_OUT=500000000   # 500 * 10^6 (positive for exact output)
cast call $HOOK "quote(bool,int256,bytes32)(uint256)" true $AMOUNT_OUT $POOL_ID --rpc-url $RPC
echo ""

echo "4. Checking hook token configuration..."
echo "Token0:"
cast call $HOOK "token0()(address)" --rpc-url $RPC
echo "Token1:"
cast call $HOOK "token1()(address)" --rpc-url $RPC
echo ""

echo "5. Checking TempoExchange balance of tokens..."
echo "Token0 balance in TempoExchange:"
cast call $TOKEN0 "balanceOf(address)(uint256)" $TEMPO_EXCHANGE --rpc-url $RPC
echo "Token1 balance in TempoExchange:"
cast call $TOKEN1 "balanceOf(address)(uint256)" $TEMPO_EXCHANGE --rpc-url $RPC
echo ""

echo "=== ALL TESTS COMPLETED ==="
