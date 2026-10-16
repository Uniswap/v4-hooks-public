// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {AllowlistedFactory} from "../src/AllowlistedFactory.sol";
import {ERC4626WrapperHook} from "../src/ERC4626WrapperHook.sol";
import {ERC4626RoutingHook} from "../src/ERC4626RoutingHook.sol";

/// @title DeployERC4626WrapperHook
/// @author Uniswap Labs
/// @notice Deploys an `ERC4626WrapperHook` (and its `ERC4626RoutingHook` quoting counterpart) for
///         one vault through the ERC-4626 wrapper family's `AllowlistedFactory` (see
///         `DeployERC4626WrapperFactory.s.sol`) so aggregators and third-party routers can
///         discover both via the factory's `Deployed` event and registry, and each hook's
///         `factory()` getter reports the canonical factory. The factory CREATE2-deploys the
///         hooks, so each address's low 14 bits must carry the hook's permission flags
///         (`address & Hooks.ALL_HOOK_MASK == 0x2888`) and, for a live deployment, a leading-zero
///         vanity prefix. The FACTORY is the CREATE2 deployer: salts must be mined against the
///         factory address, and a salt mined for any other deployer is invalid here.
///
///         Two salt paths (per hook):
///           - `HOOK_SALT` / `ROUTING_SALT` set: use salts mined offchain by
///             `script/mine_erc4626_salt.sh` (with `FACTORY` set to the same address as here; mine
///             the routing hook's salt with `HOOK_CONTRACT=src/ERC4626RoutingHook.sol:ERC4626RoutingHook`).
///             Each is re-derived and checked for BOTH the flag bits and
///             `MIN_LEADING_ZERO_NIBBLES` before any broadcast, so a stale or wrong-args salt
///             fails fast.
///           - Salt unset AND `MIN_LEADING_ZERO_NIBBLES == 0`: mine a flags-only salt in-EVM via
///             `HookMiner.find` (fine for tests / non-vanity deploys). A non-zero vanity prefix is
///             a ~2^38 search that is infeasible in-EVM, so the script reverts and points at the
///             offchain miner.
///
///         The constructor-arg encoding here MUST match the miner's
///         (`script/mine_erc4626_salt.sh` computes the same init-code hash), or the salt resolves
///         to a different address. The factory additionally requires the creation code's hash to
///         be on its allowlist, so a factory pinned to different builds rejects this script up
///         front.
///
/// @dev Env:
///        FACTORY                 (required) AllowlistedFactory address (the CREATE2 deployer).
///        POOL_MANAGER            (required) v4 PoolManager address.
///        VAULT                   (required) ERC-4626 vault whose asset the hook wraps/unwraps.
///        MIN_LEADING_ZERO_NIBBLES(default 6) required leading-zero hex digits of each address.
///        HOOK_SALT               (optional) offchain-mined wrapper hook salt.
///        ROUTING_SALT            (optional) offchain-mined routing hook salt.
///        DEPLOY_ROUTING          (default true) also deploy the ERC4626RoutingHook.
///
///      Run (dry): FACTORY=0x… POOL_MANAGER=0x… VAULT=0x… HOOK_SALT=0x… ROUTING_SALT=0x… forge script script/DeployERC4626WrapperHook.s.sol
///      Broadcast: append --rpc-url $RPC_URL --broadcast (and a --private-key / --account signer).
contract DeployERC4626WrapperHook is Script {
    /// @dev BaseTokenWrapperHook's permission bits (see {BaseTokenWrapperHook.getHookPermissions}):
    ///      beforeInitialize | beforeAddLiquidity | beforeSwap | beforeSwapReturnDelta == 0x2888.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external returns (ERC4626WrapperHook hook, ERC4626RoutingHook routingHook) {
        AllowlistedFactory factory = AllowlistedFactory(vm.envAddress("FACTORY"));
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        IERC4626 vault = IERC4626(vm.envAddress("VAULT"));
        uint256 zeroNibbles = vm.envOr("MIN_LEADING_ZERO_NIBBLES", uint256(6));
        bool deployRouting = vm.envOr("DEPLOY_ROUTING", true);

        // Both hooks share the constructor shape; MUST match the miner's encoding exactly
        // (address, address).
        bytes memory constructorArgs = abi.encode(poolManager, vault);

        hook = ERC4626WrapperHook(
            _deployThroughFactory(
                factory, type(ERC4626WrapperHook).creationCode, constructorArgs, "HOOK_SALT", zeroNibbles
            )
        );
        require(address(hook.vault()) == address(vault), "DeployERC4626WrapperHook: vault mismatch");
        console2.log("ERC4626WrapperHook deployed at:", address(hook));

        if (deployRouting) {
            routingHook = ERC4626RoutingHook(
                _deployThroughFactory(
                    factory, type(ERC4626RoutingHook).creationCode, constructorArgs, "ROUTING_SALT", zeroNibbles
                )
            );
            require(address(routingHook.vault()) == address(vault), "DeployERC4626WrapperHook: vault mismatch");
            console2.log("ERC4626RoutingHook deployed at:", address(routingHook));
        }
    }

    /// @dev Resolve the salt for `creationCode`, fail fast on any constraint violation, then
    ///      deploy through the factory so the hook is registered for aggregator discovery and its
    ///      `factory()` getter reports the canonical factory. BaseHook's constructor independently
    ///      validates the address flags, so a wrong-flag address reverts here.
    function _deployThroughFactory(
        AllowlistedFactory factory,
        bytes memory creationCode,
        bytes memory constructorArgs,
        string memory saltEnv,
        uint256 zeroNibbles
    ) internal returns (address hook) {
        // Fail before broadcasting if this build is not the one the factory was pinned to.
        require(
            factory.isAllowedCreationCode(keccak256(creationCode)),
            "DeployERC4626WrapperHook: creation code not allowed by factory (build drift?)"
        );

        (address expected, bytes32 salt) =
            _resolveSalt(address(factory), creationCode, constructorArgs, saltEnv, zeroNibbles);
        // Fail before broadcasting if the resolved address does not satisfy the constraints.
        _requireFlags(expected);
        _requireLeadingZeros(expected, zeroNibbles);

        console2.log("init-code hash:");
        console2.logBytes32(keccak256(abi.encodePacked(creationCode, constructorArgs)));
        console2.log("expected address:", expected);
        console2.log("salt:");
        console2.logBytes32(salt);

        vm.broadcast();
        hook = factory.deploy(creationCode, constructorArgs, salt);

        require(hook == expected, "DeployERC4626WrapperHook: address mismatch");
        _requireFlags(hook);
        _requireLeadingZeros(hook, zeroNibbles);
        require(ERC4626WrapperHook(hook).factory() == address(factory), "DeployERC4626WrapperHook: factory() mismatch");
        require(factory.isFromFactory(hook), "DeployERC4626WrapperHook: not registered");
    }

    /// @dev Resolve the salt: verify an offchain-mined salt from `saltEnv`, else mine flags-only
    ///      in-EVM. A mined salt is never zero (its trailing bytes are the nonce), so `bytes32(0)`
    ///      is the "not provided" sentinel. The factory is the CREATE2 deployer in both paths.
    function _resolveSalt(
        address factory,
        bytes memory creationCode,
        bytes memory constructorArgs,
        string memory saltEnv,
        uint256 zeroNibbles
    ) internal view returns (address expected, bytes32 salt) {
        salt = vm.envOr(saltEnv, bytes32(0));
        if (salt != bytes32(0)) {
            expected = HookMiner.computeAddress(factory, uint256(salt), abi.encodePacked(creationCode, constructorArgs));
        } else {
            require(
                zeroNibbles == 0,
                "DeployERC4626WrapperHook: set HOOK_SALT/ROUTING_SALT (mine with script/mine_erc4626_salt.sh) or MIN_LEADING_ZERO_NIBBLES=0"
            );
            (expected, salt) = HookMiner.find(factory, HOOK_FLAGS, creationCode, constructorArgs);
        }
    }

    /// @dev Require the address's low 14 bits equal the hook flag pattern.
    function _requireFlags(address a) internal pure {
        require(uint160(a) & HookMiner.FLAG_MASK == HOOK_FLAGS, "DeployERC4626WrapperHook: flag bits mismatch");
    }

    /// @dev Require the top `zeroNibbles` hex digits of the address to be zero.
    function _requireLeadingZeros(address a, uint256 zeroNibbles) internal pure {
        if (zeroNibbles == 0) return;
        require(zeroNibbles <= 40, "DeployERC4626WrapperHook: zeroNibbles > 40");
        require(uint160(a) >> (160 - 4 * zeroNibbles) == 0, "DeployERC4626WrapperHook: missing leading zero nibbles");
    }
}
