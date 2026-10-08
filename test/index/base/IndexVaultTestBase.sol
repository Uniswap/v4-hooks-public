// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {StablePairHook} from "../../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../../src/base/BaseDynamicFeeHook.sol";
import {ArbSysMock} from "../../../script/index-vault/ArbSysMock.sol";
import {PoolConfigLib, PoolEntry} from "../../../script/index-vault/PoolConfigLib.sol";
import {IndexLpVault} from "../../../src/index/IndexLpVault.sol";
import {IIndexLpVault} from "../../../src/index/interfaces/IIndexLpVault.sol";

/// @notice Forks 4663, deploys a StablePairHook of its own, initializes the ten fixture pools on the real PoolManager
///         and deploys the vault against the real PositionManager and Permit2. Skipped when RPC_4663 is unset (CI).
/// @dev Set FORK_BLOCK_4663 to pin every test to one block (shared fork cache, much faster). The public RPC keeps only
///      a few hours of state, so pin a recent block.
abstract contract IndexVaultTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    string constant FIXTURE = "test/index/fixtures/pools.qqq10.json";

    StablePairHook hook;
    IndexLpVault vault;
    PoolSwapTest swapRouter;
    PoolEntry[] pools;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        try vm.envString("RPC_4663") returns (string memory url) {
            uint256 forkBlock = vm.envOr("FORK_BLOCK_4663", uint256(0));
            if (forkBlock == 0) vm.createSelectFork(url);
            else vm.createSelectFork(url, forkBlock);
        } catch {
            vm.skip(true);
            return;
        }
        // 0. 0x64 holds Nitro's 0xfe placeholder on a fork: answer ArbSys before the hook's BlockNumberish probes it,
        //    so the test hook reads its block number through ArbSys exactly as the live 4663 hook does
        vm.etch(address(0x64), address(new ArbSysMock()).code);
        // 1. hook: implementation + proxy at a mined address (this contract is the CREATE2 deployer)
        StablePairHook impl = new StablePairHook(IPoolManager(POOL_MANAGER));
        bytes memory init = abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, owner, owner));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(ERC1967Proxy).creationCode, abi.encode(address(impl), init));
        hook = StablePairHook(address(new ERC1967Proxy{salt: salt}(address(impl), init)));
        assertEq(address(hook), expected);
        // 2. pools from the fixture, hook field overridden
        PoolEntry[] memory loaded = PoolConfigLib.load(vm, FIXTURE);
        for (uint256 i = 0; i < loaded.length; i++) {
            pools.push(loaded[i]);
            vm.prank(owner);
            hook.initializePool(_key(i), loaded[i].sqrtPriceX96, loaded[i].feeConfig);
        }
        // 3. vault
        IIndexLpVault.ConstituentInit[] memory inits = new IIndexLpVault.ConstituentInit[](loaded.length);
        for (uint256 i = 0; i < loaded.length; i++) {
            inits[i] = IIndexLpVault.ConstituentInit(
                loaded[i].stock,
                loaded[i].currency0,
                loaded[i].currency1,
                loaded[i].fee,
                loaded[i].tickSpacing,
                address(hook),
                loaded[i].tickLower,
                loaded[i].tickUpper,
                loaded[i].targetBps
            );
        }
        vault = new IndexLpVault(IPoolManager(POOL_MANAGER), POSM, PERMIT2, QQQ, inits, "uniQQQ10", "uniQQQ10", owner);
        vm.prank(owner);
        vault.setup();
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        // 4. fund alice from the PoolManager's real balances (fork only)
        _fundAll(alice);
    }

    /// @dev 200 QQQ and up to 500 of each stock; AVGO falls to half the PoolManager's ~92
    function _fundAll(address who) internal {
        _fund(who, QQQ, 200e18);
        for (uint256 i = 0; i < pools.length; i++) {
            _fund(who, pools[i].stock, 500e18);
        }
    }

    function _fund(address to, address token, uint256 amount) internal {
        uint256 bal = IERC20(token).balanceOf(POOL_MANAGER);
        if (bal < amount) amount = bal / 2;
        vm.prank(POOL_MANAGER);
        IERC20(token).transfer(to, amount);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        IERC20(QQQ).approve(address(vault), type(uint256).max);
        IERC20(QQQ).approve(address(swapRouter), type(uint256).max);
        for (uint256 i = 0; i < pools.length; i++) {
            IERC20(pools[i].stock).approve(address(vault), type(uint256).max);
            IERC20(pools[i].stock).approve(address(swapRouter), type(uint256).max);
        }
        vm.stopPrank();
    }

    /// @dev Approves, previews `indexValue` and deposits exactly the previewed amounts for `who`
    function _deposit(address who, uint256 indexValue) internal returns (uint256 shares) {
        _approveAll(who);
        (uint256[] memory s, uint256[] memory q,) = vault.previewDeposit(indexValue);
        vm.prank(who);
        shares = vault.deposit(s, q, 0, who);
    }

    function _key(uint256 i) internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(pools[i].currency0),
            Currency.wrap(pools[i].currency1),
            pools[i].fee,
            pools[i].tickSpacing,
            IHooks(address(hook))
        );
    }

    function _slot0(uint256 i) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = IPoolManager(POOL_MANAGER).getSlot0(_key(i).toId());
    }

    /// @dev Exact-input swap by `who` through pool i that stops at `sqrtPriceLimitX96` if the input lasts that long
    function _swap(address who, uint256 i, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96) internal {
        vm.prank(who);
        swapRouter.swap(
            _key(i),
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Moves pool i's price (currency1 per currency0) by `priceBps` (e.g. 11000 = +10%), as the only LP's swap
    function _movePrice(address who, uint256 i, uint256 priceBps) internal {
        (uint160 sqrtP,) = _slot0(i);
        uint160 target = uint160(FullMath.mulDiv(sqrtP, _sqrt(priceBps * 1e14), 1e9));
        // price up = currency1 in (oneForZero); the limit stops the swap exactly at the target
        address tokenIn = target > sqrtP ? pools[i].currency1 : pools[i].currency0;
        _swap(who, i, target < sqrtP, IERC20(tokenIn).balanceOf(who) / 2, target);
        (uint160 after_,) = _slot0(i);
        assertEq(after_, target, "price move did not reach its target");
    }

    /// @dev Value in index-token wei of `stockAmount` of pool i's stock plus `indexAmount`, at pool i's current price
    function _valueOf(uint256 i, uint256 stockAmount, uint256 indexAmount) internal view returns (uint256) {
        (uint160 sqrtP,) = _slot0(i);
        uint256 q96 = 1 << 96;
        uint256 stockValue = pools[i].stockIsCurrency0
            ? FullMath.mulDiv(FullMath.mulDiv(stockAmount, sqrtP, q96), sqrtP, q96)
            : FullMath.mulDiv(FullMath.mulDiv(stockAmount, q96, sqrtP), q96, sqrtP);
        return stockValue + indexAmount;
    }

    /// @dev Largest |bps − target| over the constituents, from allocations()
    function _maxDeviationBps() internal view returns (uint256 maxDev) {
        (, uint16[] memory bps,) = vault.allocations();
        for (uint256 i = 0; i < bps.length; i++) {
            uint256 t = pools[i].targetBps;
            uint256 dev = bps[i] > t ? bps[i] - t : t - bps[i];
            if (dev > maxDev) maxDev = dev;
        }
    }

    function _balances(address who) internal view returns (uint256[] memory stocks, uint256 index) {
        stocks = new uint256[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            stocks[i] = IERC20(pools[i].stock).balanceOf(who);
        }
        index = IERC20(QQQ).balanceOf(who);
    }

    /// @dev Integer square root scaled for the price-move helper: sqrt(x) with x in 1e18 units gives 1e9 units
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
