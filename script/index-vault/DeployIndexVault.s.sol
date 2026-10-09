// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IndexLpVault} from "../../src/index/IndexLpVault.sol";
import {IIndexLpVault} from "../../src/index/interfaces/IIndexLpVault.sol";
import {ArbSysMock} from "./ArbSysMock.sol";
import {PoolConfigLib, PoolEntry} from "./PoolConfigLib.sol";

/// @notice Deploys the IndexLpVault over the pools of a pools JSON (tooling/out/pools.4663.json), already initialized
///         on the StablePairHook at HOOK_ADDRESS, and calls the vault's setup() in the same broadcast, so OWNER must be
///         the broadcaster. Then writes tooling/deployments/<chainId>.json, the input of the tooling's exportForWeb.ts;
///         a dry run writes tooling/deployments/<chainId>.dry-run.json instead, so it never overwrites the live file.
///
/// Broadcast on Robinhood Chain (drop --broadcast for a dry run):
///   POOLS_JSON=tooling/out/pools.4663.json HOOK_ADDRESS=0xD5711B1F57e75B1c91c32AD96C4d4E5019D6Bcc0 \
///     OWNER=0x45c35C4d1bc85A1339573c3Bd5Cf0C890bbbb6c3 forge script script/index-vault/DeployIndexVault.s.sol \
///     --rpc-url $RPC_4663 --account hackathon-deployer --password-file ~/.uniswap-hackathon/keystore.pw \
///     --sender 0x45c35C4d1bc85A1339573c3Bd5Cf0C890bbbb6c3 --broadcast --skip-simulation --slow
///
/// --skip-simulation --slow as for InitIndexPools.s.sol: the node estimates each transaction's gas, and setup() is sent
/// once the vault's creation is mined.
contract DeployIndexVaultScript is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Only recorded in the deployments file: the web page reads each pool's slot0 through it
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    /// @dev ArbSys, the precompile the hook's BlockNumberish reads the block number from on Arbitrum chains
    address internal constant ARB_SYS = address(0x64);

    function run() public returns (address vaultAddr) {
        _patchArbSysForLocalExecution();
        address hook = vm.envAddress("HOOK_ADDRESS");
        address owner = vm.envAddress("OWNER");
        (PoolEntry[] memory pools, PoolId[] memory ids) = _loadPools(vm.envString("POOLS_JSON"), hook);

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(broadcaster == owner, "DeployIndexVault: OWNER must be the broadcaster, which calls setup()");
        IndexLpVault vault = new IndexLpVault(
            IPoolManager(POOL_MANAGER),
            POSM,
            PERMIT2,
            QQQ,
            _inits(pools, hook),
            "Uniswap QQQ10 LP Index",
            "uniQQQ10",
            owner
        );
        vault.setup();
        vm.stopBroadcast();
        vaultAddr = address(vault);

        console2.log("IndexLpVault deployed:", vaultAddr);
        for (uint256 i = 0; i < pools.length; i++) {
            // the poolIds written are the ones the vault stores
            require(vault.constituent(i).poolId == PoolId.unwrap(ids[i]), "DeployIndexVault: vault poolId mismatch");
            console2.log(string.concat(pools[i].symbol, " poolId ", vm.toString(PoolId.unwrap(ids[i]))));
        }
        console2.log("Wrote", _writeDeployments(hook, vaultAddr, pools, ids));
    }

    /// @dev The pools of `poolsJson` in file order (the vault's constituent order) and their PoolIds on `hook`. Reverts
    ///      unless the file is for this chain, `hook` and QQQ, and every pool is initialized on the PoolManager.
    function _loadPools(string memory poolsJson, address hook)
        internal
        view
        returns (PoolEntry[] memory pools, PoolId[] memory ids)
    {
        string memory json = vm.readFile(poolsJson);
        vm.assertEq(
            vm.parseJsonUint(json, "$.chainId"), block.chainid, "DeployIndexVault: POOLS_JSON chainId != block.chainid"
        );
        vm.assertEq(vm.parseJsonAddress(json, "$.hook"), hook, "DeployIndexVault: POOLS_JSON hook != HOOK_ADDRESS");
        vm.assertEq(vm.parseJsonAddress(json, "$.indexToken"), QQQ, "DeployIndexVault: POOLS_JSON indexToken != QQQ");
        require(hook.code.length > 0, "DeployIndexVault: no code at HOOK_ADDRESS");
        pools = PoolConfigLib.load(vm, poolsJson);
        ids = new PoolId[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            PoolConfigLib.validate(pools[i]);
            ids[i] = _key(pools[i], hook).toId();
            (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(ids[i]);
            require(sqrtPriceX96 != 0, string.concat("DeployIndexVault: ", pools[i].symbol, " pool not initialized"));
        }
    }

    function _inits(PoolEntry[] memory pools, address hook)
        internal
        pure
        returns (IIndexLpVault.ConstituentInit[] memory inits)
    {
        inits = new IIndexLpVault.ConstituentInit[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            inits[i] = IIndexLpVault.ConstituentInit(
                pools[i].stock,
                pools[i].currency0,
                pools[i].currency1,
                pools[i].fee,
                pools[i].tickSpacing,
                hook,
                pools[i].tickLower,
                pools[i].tickUpper,
                pools[i].targetBps
            );
        }
    }

    function _key(PoolEntry memory e, address hook) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(e.currency0), Currency.wrap(e.currency1), e.fee, e.tickSpacing, IHooks(hook));
    }

    /// @dev Writes tooling/deployments/<chainId>.json and returns its path: the addresses the web page needs and, per
    ///      constituent in vault order, its pool key, PoolId, range and target weight. Numbers are JSON numbers and
    ///      addresses checksummed; vm.writeJson sorts the keys. A string[] of serialized objects serializes as an
    ///      array of objects.
    function _writeDeployments(address hook, address vault, PoolEntry[] memory pools, PoolId[] memory ids)
        internal
        returns (string memory path)
    {
        string[] memory constituents = new string[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            string memory obj = string.concat("constituent", vm.toString(i));
            vm.serializeString(obj, "symbol", pools[i].symbol);
            vm.serializeAddress(obj, "stock", pools[i].stock);
            vm.serializeBytes32(obj, "poolId", PoolId.unwrap(ids[i]));
            vm.serializeAddress(obj, "currency0", pools[i].currency0);
            vm.serializeAddress(obj, "currency1", pools[i].currency1);
            vm.serializeInt(obj, "tickSpacing", pools[i].tickSpacing);
            vm.serializeInt(obj, "tickLower", pools[i].tickLower);
            vm.serializeInt(obj, "tickUpper", pools[i].tickUpper);
            constituents[i] = vm.serializeUint(obj, "targetBps", pools[i].targetBps);
        }
        string memory root = "deployments";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "hook", hook);
        vm.serializeAddress(root, "vault", vault);
        vm.serializeAddress(root, "indexToken", QQQ);
        vm.serializeAddress(root, "positionManager", POSM);
        vm.serializeAddress(root, "poolManager", POOL_MANAGER);
        vm.serializeAddress(root, "stateView", STATE_VIEW);
        string memory json = vm.serializeString(root, "constituents", constituents);
        vm.createDir("tooling/deployments", true);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        path =
            string.concat("tooling/deployments/", vm.toString(block.chainid), broadcasting ? ".json" : ".dry-run.json");
        vm.writeJson(json, path);
    }

    /// @dev As in InitIndexPools.s.sol: a fork holds only Nitro's one-byte placeholder (0xfe) at ArbSys, which forge
    ///      executes as INVALID. The vault's constructor makes no calls and setup() calls only the tokens and Permit2,
    ///      so this is a precaution for the local run; the broadcast transactions are unchanged.
    function _patchArbSysForLocalExecution() internal {
        if (ARB_SYS.code.length == 1) {
            vm.etch(ARB_SYS, address(new ArbSysMock()).code);
            console2.log("Local run: patched ArbSys (0x64) with ArbSysMock; broadcast transactions are unchanged");
        }
    }
}
