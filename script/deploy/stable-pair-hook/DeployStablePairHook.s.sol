// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {StablePairHook} from "../../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../../src/base/BaseDynamicFeeHook.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";

/// @notice Deploys the StablePairHook implementation and its ERC1967 proxy. The proxy is the
///         registered v4 hook, so its address (not the implementation's) is mined for the flags.
///
///         Three entry points, using this chain's entry in Parameters.sol:
///         - `run()`: implementation (if `stablePairHookImplementation` is not set yet), then proxy
///         - `--sig "deployImplementation()"`: implementation only; record the printed address in
///           `stablePairHookImplementation`
///         - `--sig "deployProxy()"`: proxy only, pointing at `stablePairHookImplementation`
contract DeployStablePairHookScript is Script, Parameters {
    error AddressMismatch(address deployed, address expected);
    error FlagsMismatch(address deployed, uint160 flags);
    error RolesNotSetForChainId(uint256 chainId);
    error ImplementationMismatch(address current, address expected);
    error RolesMismatch(address proxy);
    error InvalidImplementation(address implementation);

    /// @dev Must match BaseDynamicFeeHook.getHookPermissions(); the proxy's mined address freezes
    ///      this flag set forever
    uint160 public constant STABLE_PAIR_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function run() public returns (address) {
        DeployParameters memory params = getParameters(block.chainid);
        // Checked before anything is broadcast, so a missing role can't leave a lone implementation
        _checkRoles(params);
        address implementation = params.stablePairHookImplementation == address(0)
            ? _deployImplementation(params)
            : _checkImplementation(params);
        return _deployProxy(params, implementation);
    }

    function deployImplementation() public returns (address) {
        DeployParameters memory params = getParameters(block.chainid);
        if (params.stablePairHookImplementation != address(0)) return _checkImplementation(params);
        return _deployImplementation(params);
    }

    function deployProxy() public returns (address) {
        DeployParameters memory params = getParameters(block.chainid);
        _checkRoles(params);
        return _deployProxy(params, _checkImplementation(params));
    }

    function _checkRoles(DeployParameters memory params) internal view {
        if (params.owner == address(0) || params.poolInitializer == address(0) || params.configManager == address(0)) {
            revert RolesNotSetForChainId(block.chainid);
        }
    }

    /// @notice Validates the recorded implementation: it must exist and use this chain's PoolManager
    function _checkImplementation(DeployParameters memory params) internal view returns (address implementation) {
        implementation = params.stablePairHookImplementation;
        if (
            implementation.code.length == 0
                || address(StablePairHook(implementation).poolManager()) != address(params.poolManager)
        ) revert InvalidImplementation(implementation);
        console2.log("Using StablePairHook implementation at:", implementation);
    }

    /// @notice Deploys the implementation via CREATE2 at a mined address that carries no hook-flag
    ///         bits. The miner counts up from salt 0, so the address is deterministic per chain
    function _deployImplementation(DeployParameters memory params) internal returns (address implementation) {
        bytes32 salt;
        (implementation, salt) = HookMiner.find(
            CREATE2_DEPLOYER, uint160(0), type(StablePairHook).creationCode, abi.encode(params.poolManager)
        );
        vm.broadcast();
        StablePairHook deployedImplementation = new StablePairHook{salt: salt}(params.poolManager);
        if (address(deployedImplementation) != implementation) {
            revert AddressMismatch(address(deployedImplementation), implementation);
        }
        console2.log("StablePairHook implementation deployed to:", implementation);
        console2.log("Record it as stablePairHookImplementation in Parameters.sol");
    }

    /// @notice Deploys the proxy at a mined hook address, initializing the roles atomically
    function _deployProxy(DeployParameters memory params, address implementation) internal returns (address) {
        bytes memory initializeCall =
            abi.encodeCall(BaseDynamicFeeHook.initialize, (params.owner, params.poolInitializer, params.configManager));
        bytes memory proxyConstructorArgs = abi.encode(implementation, initializeCall);

        (address expectedAddress, bytes32 salt) = _resolveCreate2Address(
            params.stablePairHookProxySalt,
            STABLE_PAIR_HOOK_FLAGS,
            type(ERC1967Proxy).creationCode,
            proxyConstructorArgs,
            "proxy"
        );

        if (expectedAddress.code.length > 0) {
            address currentImplementation =
                address(uint160(uint256(vm.load(expectedAddress, ERC1967Utils.IMPLEMENTATION_SLOT))));
            if (currentImplementation != implementation) {
                revert ImplementationMismatch(currentImplementation, implementation);
            }
            StablePairHook existing = StablePairHook(expectedAddress);
            if (
                !existing.hasRole(existing.DEFAULT_ADMIN_ROLE(), params.owner)
                    || !existing.hasRole(existing.POOL_INITIALIZER_ROLE(), params.poolInitializer)
                    || !existing.hasRole(existing.CONFIG_MANAGER_ROLE(), params.configManager)
            ) {
                revert RolesMismatch(expectedAddress);
            }
            console2.log("Skipping deployment, StablePairHook proxy already exists at:", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(implementation, initializeCall);

        // Matching expectedAddress also pins the flags: they were verified when it was resolved
        if (address(proxy) != expectedAddress) {
            revert AddressMismatch(address(proxy), expectedAddress);
        }

        console2.log("StablePairHook (proxy) deployed to:", address(proxy));
        return address(proxy);
    }

    /// @notice Resolves the CREATE2 address for `creationCode` + `constructorArgs`: uses the
    ///         cached salt when set, otherwise mines one whose address encodes exactly `flags`.
    ///         Either way, the resolved address' flag bits are verified before it is used.
    function _resolveCreate2Address(
        bytes32 cachedSalt,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        string memory label
    ) internal view returns (address expected, bytes32 salt) {
        console2.log(string.concat(label, " init code hash (for external salt mining):"));
        console2.logBytes32(keccak256(abi.encodePacked(creationCode, constructorArgs)));

        if (cachedSalt != bytes32(0)) {
            // Use the cached salt for a deterministic address
            salt = cachedSalt;
            expected = HookMiner.computeAddress(
                CREATE2_DEPLOYER, uint256(salt), abi.encodePacked(creationCode, constructorArgs)
            );
        } else {
            (expected, salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);
            console2.log(
                string.concat("Mined ", label, " salt (cache it in Parameters.sol for deterministic deployments):")
            );
            console2.logBytes32(salt);
        }
        if (uint160(expected) & Hooks.ALL_HOOK_MASK != flags) revert FlagsMismatch(expected, flags);
    }
}
