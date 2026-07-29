// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ERC4626WrapperHook} from "../src/ERC4626WrapperHook.sol";
import {TestRouter} from "./shared/TestRouter.sol";

interface IVaultCallback {
    function onVaultDeposit() external;
    function onVaultRedeem() external;
}

/// @notice ERC-4626 vault that hands control to a third party while a deposit or a redemption is
///         still in flight, i.e. while the hook holds tokens belonging to the in-flight swap and has
///         a settlement pending. Real vaults reach third-party code at these points via strategy
///         adapters, AMM legs in the withdrawal path, or callback-capable assets.
contract MaliciousERC4626Vault is ERC20 {
    address public immutable asset;
    address public callbackTarget;
    bool private _reentered;

    constructor(address _asset) ERC20("Malicious Vault", "mVLT", 18) {
        asset = _asset;
    }

    function setCallbackTarget(address target) external {
        callbackTarget = target;
    }

    function totalAssets() public view returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : (shares * totalAssets() + supply - 1) / supply;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : (assets * supply + totalAssets() - 1) / totalAssets();
    }

    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = previewDeposit(assets);
        ERC20(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        _fire(true);
    }

    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        assets = convertToAssets(shares);
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }
        _burn(owner, shares);
        ERC20(asset).transfer(receiver, assets);
        _fire(false);
    }

    function _fire(bool isDeposit) internal {
        if (callbackTarget == address(0) || _reentered) return;
        _reentered = true;
        if (isDeposit) {
            IVaultCallback(callbackTarget).onVaultDeposit();
        } else {
            IVaultCallback(callbackTarget).onVaultRedeem();
        }
        _reentered = false;
    }
}

/// @notice Reached by the vault while the victim's swap is mid-flight. The PoolManager is unlocked by
///         the victim's router at that point, so this contract can swap and settle freely.
contract Attacker is IVaultCallback {
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    enum Mode {
        Idle,
        NestedWrap, // capture the in-flight unwrap's proceeds via a nested wrap
        NestedUnwrap, // capture the in-flight wrap's proceeds via a nested unwrap
        SyncGrief // overwrite the pending CurrencyReserves snapshot
    }

    IPoolManager public immutable manager;
    ERC20 public immutable underlying;
    ERC20 public immutable shares;
    Currency public immutable decoy;

    PoolKey internal key;
    bool internal wrapZeroForOne;
    Mode public mode;
    uint256 public dust;
    bool public fired;

    constructor(IPoolManager _manager, ERC20 _underlying, ERC20 _shares, Currency _decoy) {
        manager = _manager;
        underlying = _underlying;
        shares = _shares;
        decoy = _decoy;
    }

    function arm(PoolKey memory _key, bool _wrapZeroForOne, Mode _mode, uint256 _dust) external {
        key = _key;
        wrapZeroForOne = _wrapZeroForOne;
        mode = _mode;
        dust = _dust;
        fired = false;
    }

    function onVaultDeposit() external override {
        if (mode == Mode.NestedUnwrap) {
            fired = true;
            _nestedSwap(!wrapZeroForOne, shares, underlying);
        } else if (mode == Mode.SyncGrief) {
            fired = true;
            manager.sync(decoy);
        }
    }

    function onVaultRedeem() external override {
        if (mode != Mode.NestedWrap) return;
        fired = true;
        _nestedSwap(wrapZeroForOne, underlying, shares);
    }

    /// @dev Pays `dust` of the input currency, swaps, and takes whatever the hook credits.
    function _nestedSwap(bool zeroForOne, ERC20 tokenIn, ERC20 tokenOut) internal {
        Currency currencyIn = Currency.wrap(address(tokenIn));
        Currency currencyOut = Currency.wrap(address(tokenOut));

        manager.sync(currencyIn);
        tokenIn.transfer(address(manager), dust);
        manager.settle();

        manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -dust.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int256 credit = manager.currencyDelta(address(this), currencyOut);
        if (credit > 0) manager.take(currencyOut, address(this), uint256(credit));
    }
}

/// @title ERC4626WrapperHook — in-flight settlement attacks
/// @notice Each test arms a vault that reaches attacker-controlled code while the victim's swap is
///         mid-flight, then asserts the victim is not shortchanged. The non-reverting test also
///         asserts the callback fired, so it cannot pass by never running the attack; the reverting
///         tests match exact revert arguments instead, since a revert rolls that flag back.
contract ERC4626WrapperHookAttackTest is Test, Deployers {
    using SafeCast for uint256;

    ERC4626WrapperHook hook;
    MockERC20 underlying;
    MockERC20 decoy;
    MaliciousERC4626Vault vault;
    Attacker attacker;
    TestRouter router;

    PoolKey poolKey;
    bool wrapZeroForOne;

    address victim = makeAddr("victim");

    uint256 constant SEED = 1_000_000 ether;
    uint256 constant VICTIM_AMOUNT = 1000 ether;
    uint256 constant DUST = 1;

    function setUp() public {
        deployFreshManagerAndRouters();
        router = new TestRouter(manager);

        underlying = new MockERC20("Asset", "AST", 18);
        decoy = new MockERC20("Decoy", "DCY", 18);
        vault = new MaliciousERC4626Vault(address(underlying));

        // seed the vault so shares are fully backed at a 1:1 rate
        underlying.mint(address(this), SEED);
        underlying.approve(address(vault), type(uint256).max);
        vault.deposit(SEED, address(this));

        uint160 flags = uint160(
            type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
        );
        hook = ERC4626WrapperHook(address(flags));
        deployCodeTo("ERC4626WrapperHook", abi.encode(manager, IERC4626(address(vault))), address(hook));

        wrapZeroForOne = address(underlying) < address(vault);
        (Currency currency0, Currency currency1) = wrapZeroForOne
            ? (Currency.wrap(address(underlying)), Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), Currency.wrap(address(underlying)));
        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        attacker = new Attacker(manager, underlying, ERC20(address(vault)), Currency.wrap(address(decoy)));
        vault.setCallbackTarget(address(attacker));

        // the attacker's entire capital
        underlying.mint(address(attacker), DUST);
        assertTrue(vault.transfer(address(attacker), DUST));

        underlying.mint(victim, VICTIM_AMOUNT);
        assertTrue(vault.transfer(victim, VICTIM_AMOUNT));
        vm.startPrank(victim);
        underlying.approve(address(router), type(uint256).max);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swapExactIn(bool zeroForOne, uint256 amountIn) internal {
        vm.prank(victim);
        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -amountIn.toInt256(), sqrtPriceLimitX96: _limit(zeroForOne)
            }),
            ""
        );
    }

    function _expectSettlementMismatch() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ERC4626WrapperHook.SettlementMismatch.selector, VICTIM_AMOUNT, 0),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @notice The vault redeems the victim's shares, then hands control to the attacker, who wraps
    ///         1 wei against the same pool. The nested wrap must not be credited with the victim's
    ///         redemption proceeds.
    function test_attack_nestedWrapCannotCaptureUnwrapProceeds() public {
        uint256 expectedOut = vault.previewRedeem(VICTIM_AMOUNT);
        attacker.arm(poolKey, wrapZeroForOne, Attacker.Mode.NestedWrap, DUST);

        uint256 victimUnderlyingBefore = underlying.balanceOf(victim);
        uint256 attackerSharesBefore = vault.balanceOf(address(attacker));

        _swapExactIn(!wrapZeroForOne, VICTIM_AMOUNT);

        assertTrue(attacker.fired(), "attack path did not execute");
        assertEq(underlying.balanceOf(victim) - victimUnderlyingBefore, expectedOut, "victim was shortchanged");
        // the attacker gets only what its own 1 wei bought
        assertLe(vault.balanceOf(address(attacker)) - attackerSharesBefore, DUST, "attacker captured victim proceeds");
    }

    /// @notice Mirror image: the victim wraps, and the attacker unwraps 1 wei from inside the
    ///         vault's deposit. The nested settlement consumes the hook's pending CurrencyReserves
    ///         snapshot, so the swap must fail rather than credit the victim nothing.
    function test_attack_nestedUnwrapCannotCaptureWrapProceeds() public {
        attacker.arm(poolKey, wrapZeroForOne, Attacker.Mode.NestedUnwrap, DUST);

        _expectSettlementMismatch();
        _swapExactIn(wrapZeroForOne, VICTIM_AMOUNT);

        assertEq(underlying.balanceOf(victim), VICTIM_AMOUNT, "victim did not keep its funds");
        assertEq(vault.balanceOf(victim), VICTIM_AMOUNT, "victim did not keep its shares");
    }

    /// @notice The attacker never touches the hook, only the PoolManager: it overwrites the pending
    ///         snapshot with an unrelated currency so that settle() measures the wrong balance.
    /// @dev The reverting tests cannot assert `attacker.fired()`, because the revert rolls that flag
    ///      back. The revert arguments are stronger evidence anyway: a settled amount of 0 alongside
    ///      a measured VICTIM_AMOUNT is only reachable if the pending snapshot was overwritten.
    function test_attack_syncGriefCannotZeroTheOutput() public {
        attacker.arm(poolKey, wrapZeroForOne, Attacker.Mode.SyncGrief, 0);

        _expectSettlementMismatch();
        _swapExactIn(wrapZeroForOne, VICTIM_AMOUNT);

        assertEq(underlying.balanceOf(victim), VICTIM_AMOUNT, "victim did not keep its funds");
    }
}
