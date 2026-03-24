// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {BaseALFHook} from "./base/BaseALFHook.sol";
import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";

/// @title RepositioningJITQuoterHook
/// @notice JIT liquidity repositioning quoter that manages its own LP inventory and repositions
///         it around a market maker's target price before each swap. LP persists between swaps
///         (no afterSwap removal). Pricing is controlled via fee overrides and EIP-712 signed
///         config updates.
contract RepositioningJITQuoterHook is BaseALFHook, EIP712, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ──── Config & State ────

    struct RepositioningConfig {
        int24 targetTick; // Market maker's fair-value tick (center of LP range)
        int24 tickWidth; // Half-width of LP range (ticks, before alignment)
        uint128 liquidity; // Liquidity units to deploy
        uint24 bidFeePips; // Fee override for zeroForOne swaps
        uint24 askFeePips; // Fee override for oneForZero swaps
        uint128 bidCoefficient; // Indicative quote coefficient for zeroForOne (1e18)
        uint128 askCoefficient; // Indicative quote coefficient for oneForZero (1e18)
        uint16 attestedDiscountBps; // Discount for attested indicative quotes
        bool live;
    }

    struct ActivePosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @dev Salt used for all managed LP positions.
    bytes32 public constant REPO_SALT = bytes32(uint256(0x5245504f)); // "REPO"

    bytes32 private constant REPO_CONFIG_UPDATE_TYPEHASH = keccak256(
        "RepoConfigUpdate(int24 targetTick,int24 tickWidth,uint128 liquidity,uint24 bidFeePips,uint24 askFeePips,uint128 bidCoefficient,uint128 askCoefficient,uint16 attestedDiscountBps,bool live,bytes32 poolId,uint256 deadline)"
    );

    mapping(PoolId => RepositioningConfig) public repoConfig;
    mapping(PoolId => ActivePosition) public activePosition;

    // ──── Events ────

    event ConfigUpdated(PoolId indexed poolId, RepositioningConfig config);
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);
    event Deposit(Currency indexed token, uint256 amount);
    event Withdrawal(Currency indexed token, uint256 amount);
    event PositionWithdrawn(PoolId indexed poolId);

    // ──── Errors ────

    error LiquidityNotAllowed();

    // ──── Constructor ────

    constructor(
        IPoolManager _poolManager,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_
    )
        BaseALFHook(_poolManager, _attestationRegistry, maxGas_)
        EIP712("RepositioningJITQuoterHook", "1")
        Ownable(owner_)
    {}

    // ──── Hook Permissions ────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──── IALFHook ────

    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @notice Indicative quote with hookData-aware pricing.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        (bytes memory curveUpdateData, bool isAttested,) = _resolveHookData(hookData);

        RepositioningConfig memory config = repoConfig[key.toId()];
        if (curveUpdateData.length > 0) {
            (RepositioningConfig memory newConfig,,,) =
                abi.decode(curveUpdateData, (RepositioningConfig, PoolId, uint256, bytes));
            config = newConfig;
        }

        return _priceWithConfig(zeroForOne, amountSpecified, isAttested, config);
    }

    // ──── Hook Lifecycle ────

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (bytes memory curveUpdateData,,) = _resolveHookData(hookData);
        if (curveUpdateData.length > 0) {
            _applyCurveUpdate(key.toId(), curveUpdateData);
        }

        PoolId poolId = key.toId();
        RepositioningConfig memory config = repoConfig[poolId];

        if (!config.live || config.liquidity == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 2. Reposition LP (remove old + add new + settle net delta)
        _reposition(key, poolId, config);

        // 3. Return fee override
        uint24 feePips = params.zeroForOne ? config.bidFeePips : config.askFeePips;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Remove old LP (if any), add new LP centered on target tick, settle net delta.
    function _reposition(PoolKey calldata key, PoolId poolId, RepositioningConfig memory config) private {
        // Remove existing position if any
        ActivePosition memory oldPos = activePosition[poolId];
        BalanceDelta removeDelta;
        if (oldPos.liquidity > 0) {
            (removeDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: oldPos.tickLower,
                    tickUpper: oldPos.tickUpper,
                    liquidityDelta: -int256(uint256(oldPos.liquidity)),
                    salt: REPO_SALT
                }),
                ""
            );
        }

        // Compute new tick range centered on target
        (int24 newTickLower, int24 newTickUpper) =
            _computeTickRange(config.targetTick, config.tickWidth, key.tickSpacing);

        // Validate tick range and pool state
        {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            if (newTickLower >= newTickUpper || sqrtPriceX96 == 0) {
                if (oldPos.liquidity > 0) {
                    _settleBalanceDelta(key, removeDelta);
                }
                activePosition[poolId] = ActivePosition(0, 0, 0);
                return;
            }
        }

        // Add new LP at target
        (BalanceDelta addDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(config.liquidity)),
                salt: REPO_SALT
            }),
            ""
        );

        // Net settle the remove + add deltas
        _settleNetDelta(key, removeDelta, addDelta);

        // Update active position
        activePosition[poolId] = ActivePosition(newTickLower, newTickUpper, config.liquidity);
    }

    // ──── Pricing ────

    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool isAttested, address)
        internal
        view
        override
        returns (uint256)
    {
        return _priceWithConfig(zeroForOne, amountSpecified, isAttested, repoConfig[key.toId()]);
    }

    function _priceWithConfig(
        bool zeroForOne,
        int256 amountSpecified,
        bool isAttested,
        RepositioningConfig memory config
    ) internal pure returns (uint256 outputAmount) {
        if (!config.live) return 0;

        uint256 amount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint128 coefficient = zeroForOne ? config.bidCoefficient : config.askCoefficient;
        outputAmount = (amount * coefficient) / 1e18;

        if (isAttested && config.attestedDiscountBps > 0) {
            outputAmount = (outputAmount * (10_000 + uint256(config.attestedDiscountBps))) / 10_000;
        }
    }

    // ──── Curve Update (EIP-712 Signed) ────

    function _applyCurveUpdate(PoolId poolId, bytes memory curveUpdateData) internal {
        (RepositioningConfig memory newConfig, PoolId updatePoolId, uint256 deadline, bytes memory sig) =
            abi.decode(curveUpdateData, (RepositioningConfig, PoolId, uint256, bytes));

        _validateCurveUpdateMeta(poolId, updatePoolId, deadline);

        if (_checkAndMarkCurveUpdate(poolId, curveUpdateData)) {
            _verifySignature(newConfig, poolId, deadline, sig);
            repoConfig[poolId] = newConfig;
            emit ConfigUpdated(poolId, newConfig);
        }
    }

    function _verifySignature(RepositioningConfig memory config, PoolId poolId, uint256 deadline, bytes memory sig)
        internal
        view
    {
        bytes32 structHash = keccak256(
            abi.encode(
                REPO_CONFIG_UPDATE_TYPEHASH,
                config.targetTick,
                config.tickWidth,
                config.liquidity,
                config.bidFeePips,
                config.askFeePips,
                config.bidCoefficient,
                config.askCoefficient,
                config.attestedDiscountBps,
                config.live,
                PoolId.unwrap(poolId),
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, sig);
        if (signer != priceSigner) revert InvalidPriceSigner();
    }

    // ──── Settlement Helpers ────

    function _settleNetDelta(PoolKey calldata key, BalanceDelta removeDelta, BalanceDelta addDelta) internal {
        _settleOrTake(key.currency0, removeDelta.amount0() + addDelta.amount0());
        _settleOrTake(key.currency1, removeDelta.amount1() + addDelta.amount1());
    }

    function _settleBalanceDelta(PoolKey calldata key, BalanceDelta delta) internal {
        _settleOrTake(key.currency0, delta.amount0());
        _settleOrTake(key.currency1, delta.amount1());
    }

    function _settleOrTake(Currency currency, int128 net) internal {
        if (net < 0) {
            _settle(currency, address(this), uint256(int256(-net)));
        } else if (net > 0) {
            _take(currency, address(this), uint256(int256(net)));
        }
    }

    /// @dev Compute tick range centered on targetTick, aligned to tickSpacing.
    function _computeTickRange(int24 targetTick, int24 tickWidth, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        tickLower = ((targetTick - tickWidth) / tickSpacing) * tickSpacing;
        tickUpper = ((targetTick + tickWidth) / tickSpacing) * tickSpacing;
        if (tickUpper <= tickLower) {
            tickUpper = tickLower + tickSpacing;
        }
    }

    // ──── Inventory Management ────

    /// @notice Deposit ERC-20 tokens into the hook's inventory.
    function deposit(Currency token, uint256 amount) external onlyOwner {
        IERC20Minimal(Currency.unwrap(token)).transferFrom(msg.sender, address(this), amount);
        emit Deposit(token, amount);
    }

    /// @notice Withdraw ERC-20 tokens from the hook's inventory.
    function withdraw(Currency token, uint256 amount) external onlyOwner {
        IERC20Minimal(Currency.unwrap(token)).transfer(msg.sender, amount);
        emit Withdrawal(token, amount);
    }

    /// @notice Emergency: remove active LP position and take tokens as ERC-20.
    function emergencyWithdrawPosition(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        ActivePosition memory pos = activePosition[poolId];
        if (pos.liquidity == 0) return;
        activePosition[poolId] = ActivePosition(0, 0, 0);
        poolManager.unlock(abi.encode(key, pos));
        emit PositionWithdrawn(poolId);
    }

    /// @dev Called by PM during unlock. Removes LP and takes tokens.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, ActivePosition memory pos) = abi.decode(data, (PoolKey, ActivePosition));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: REPO_SALT
            }),
            ""
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (d0 > 0) _take(key.currency0, address(this), uint256(int256(d0)));
        if (d1 > 0) _take(key.currency1, address(this), uint256(int256(d1)));

        return "";
    }

    // ──── Owner Functions ────

    /// @notice Update the repositioning configuration for a pool.
    function updateConfig(PoolKey calldata key, RepositioningConfig calldata config) external onlyOwner {
        repoConfig[key.toId()] = config;
        emit ConfigUpdated(key.toId(), config);
    }

    /// @notice Toggle liveness for a pool.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner {
        repoConfig[key.toId()].live = live;
        emit PoolLivenessUpdated(key.toId(), live);
    }

    /// @notice Set the authorized price signer for hookData curve updates.
    function setPriceSigner(address _priceSigner) external onlyOwner {
        priceSigner = _priceSigner;
        emit PriceSignerUpdated(_priceSigner);
    }
}
