// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StablePairHook} from "../../src/stable/StablePairHook.sol";
import {ArbSysMock} from "./ArbSysMock.sol";
import {PoolConfigLib, PoolEntry} from "./PoolConfigLib.sol";

/// @notice Initializes every pool of a pools JSON (tooling/out/pools.4663.json) on the StablePairHook, each with its
///         fee config, and logs each PoolId. The broadcaster must hold the hook's POOL_INITIALIZER_ROLE.
///
/// Broadcast on Robinhood Chain (drop --broadcast for a dry run):
///   POOLS_JSON=tooling/out/pools.4663.json HOOK_ADDRESS=0x... forge script script/index-vault/InitIndexPools.s.sol \
///     --rpc-url $RPC_4663 --account hackathon-deployer --password-file ~/.uniswap-hackathon/keystore.pw \
///     --sender 0x45c35C4d1bc85A1339573c3Bd5Cf0C890bbbb6c3 --broadcast --skip-simulation --slow
///
/// Why --skip-simulation --slow: forge's on-chain simulation replays the transactions on a fresh fork without the
/// local ArbSys patch below, so it reverts on the same placeholder. Skipped, forge has the node estimate each
/// transaction's gas against the real precompile, and --slow sends one transaction at a time.
contract InitIndexPoolsScript is Script {
    using PoolIdLibrary for PoolKey;

    /// @dev ArbSys, the precompile the hook's BlockNumberish reads the block number from on Arbitrum chains
    address internal constant ARB_SYS = address(0x64);

    function run() public {
        initializePools(vm.envAddress("HOOK_ADDRESS"), vm.envString("POOLS_JSON"));
    }

    /// @notice Initializes each pool of `poolsJson` on `hook` and returns the PoolIds in file order
    function initializePools(address hook, string memory poolsJson) public returns (PoolId[] memory ids) {
        _patchArbSysForLocalExecution();
        vm.assertEq(
            PoolConfigLib.chainId(vm, poolsJson), block.chainid, "InitIndexPools: POOLS_JSON chainId != block.chainid"
        );
        require(hook.code.length > 0, "InitIndexPools: no code at HOOK_ADDRESS");
        PoolEntry[] memory pools = PoolConfigLib.load(vm, poolsJson);
        for (uint256 i = 0; i < pools.length; i++) {
            PoolConfigLib.validate(pools[i]);
        }

        ids = new PoolId[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(pools[i].currency0),
                currency1: Currency.wrap(pools[i].currency1),
                fee: pools[i].fee,
                tickSpacing: pools[i].tickSpacing,
                hooks: IHooks(hook)
            });
            ids[i] = key.toId();
            vm.broadcast();
            int24 tick = StablePairHook(hook).initializePool(key, pools[i].sqrtPriceX96, pools[i].feeConfig);
            console2.log(
                string.concat(
                    pools[i].symbol,
                    " initialized at tick ",
                    vm.toString(tick),
                    ", poolId ",
                    vm.toString(PoolId.unwrap(ids[i]))
                )
            );
        }
    }

    /// @dev The live hook's BlockNumberish reads ArbSys (its _USE_ARB_SYS immutable is true on 4663) and reverts when
    ///      the call fails. A fork holds only Nitro's one-byte placeholder (0xfe) at 0x64, which forge executes as
    ///      INVALID, so every local initializePool would revert. The etch changes only the local EVM: the broadcast
    ///      transactions are the plain initializePool calls, answered on-chain by the real precompile.
    function _patchArbSysForLocalExecution() internal {
        if (ARB_SYS.code.length == 1) {
            vm.etch(ARB_SYS, address(new ArbSysMock()).code);
            console2.log("Local run: patched ArbSys (0x64) with ArbSysMock; broadcast transactions are unchanged");
        }
    }
}
