// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
// Referenced only by name in `deployCodeTo`; imported so forge includes its artifact in the build.
import {ERC1967Proxy as _ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StablePairHook} from "../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {ArbSysMock} from "../../script/index-vault/ArbSysMock.sol";
import {PoolConfigLib, PoolEntry} from "../../script/index-vault/PoolConfigLib.sol";
import {InitIndexPoolsScript} from "../../script/index-vault/InitIndexPools.s.sol";

abstract contract PoolsSampleFixture is Test {
    string internal constant FIXTURE = "test/index/fixtures/pools.sample.json";
    address internal constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant ARB_SYS = address(0x64);

    /// @dev currentTick is in the file but not in PoolEntry, so it is read straight from the JSON
    function _currentTick(string memory json, uint256 i) internal pure returns (int24) {
        return int24(vm.parseJsonInt(json, string.concat("$.pools[", vm.toString(i), "].currentTick")));
    }
}

/// @notice The loader, the fixture, and the script's guards
contract InitIndexPoolsTest is PoolsSampleFixture {
    function test_parsesFixture() public view {
        PoolEntry[] memory pools = PoolConfigLib.load(vm, "test/index/fixtures/pools.sample.json");
        assertEq(pools.length, 2);
        assertEq(pools[0].symbol, "NVDA");
        assertTrue(pools[0].currency0 < pools[0].currency1);
        assertEq(pools[0].tickSpacing, 10);
        assertEq(pools[0].feeConfig.optimalFeeE6, 5000);
    }

    /// @dev forge 1.7.1 cannot decode `$.pools` as an array, so load() counts entries up to the first missing index
    function test_load_countsEntriesUpToTheFirstMissingIndex() public view {
        string memory json = vm.readFile(FIXTURE);
        assertTrue(vm.keyExistsJson(json, "$.pools[1]"));
        assertFalse(vm.keyExistsJson(json, "$.pools[2]"));
        assertEq(PoolConfigLib.load(vm, FIXTURE).length, 2);
    }

    /// @dev The prices are 29-digit decimal strings, so a float64 parse would lose their low bits
    function test_load_parsesSqrtPricesExactly() public view {
        PoolEntry[] memory pools = PoolConfigLib.load(vm, FIXTURE);
        assertEq(pools[0].sqrtPriceX96, 44012652675569666051086298181);
        assertEq(pools[0].feeConfig.referenceSqrtPriceX96, 44012652675569666051086298181);
        assertEq(pools[1].sqrtPriceX96, 53418821111166287841525052746);
        assertEq(pools[1].feeConfig.referenceSqrtPriceX96, 53418821111166287841525052746);
    }

    function test_load_parsesEveryField() public view {
        PoolEntry memory p = PoolConfigLib.load(vm, FIXTURE)[1];
        assertEq(p.symbol, "AAPL");
        assertEq(p.stock, AAPL);
        assertEq(p.currency0, AAPL);
        assertEq(p.currency1, QQQ);
        assertTrue(p.stockIsCurrency0);
        assertEq(p.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(p.tickSpacing, 10);
        assertEq(p.tickLower, -9290);
        assertEq(p.tickUpper, -6480);
        assertEq(p.targetBps, 1484);
        assertEq(p.feeConfig.k, 16757000);
        assertEq(p.feeConfig.optimalFeeE6, 3000);
        assertEq(p.feeConfig.targetMultiplier, 100);
        assertEq(PoolConfigLib.chainId(vm, FIXTURE), 4663);
    }

    /// @dev Each entry pairs its stock with the index token, sorted, priced at the currentTick it records
    function test_fixture_isSelfConsistent() public view {
        string memory json = vm.readFile(FIXTURE);
        address indexToken = vm.parseJsonAddress(json, "$.indexToken");
        assertEq(indexToken, QQQ);
        PoolEntry[] memory pools = PoolConfigLib.load(vm, FIXTURE);
        for (uint256 i = 0; i < pools.length; i++) {
            PoolEntry memory p = pools[i];
            int24 currentTick = _currentTick(json, i);
            assertEq(p.stockIsCurrency0 ? p.currency0 : p.currency1, p.stock, p.symbol);
            assertEq(p.stockIsCurrency0 ? p.currency1 : p.currency0, indexToken, p.symbol);
            assertLt(uint160(p.currency0), uint160(p.currency1), p.symbol);
            assertEq(p.feeConfig.referenceSqrtPriceX96, p.sqrtPriceX96, p.symbol);
            assertEq(TickMath.getTickAtSqrtPrice(p.sqrtPriceX96), currentTick, p.symbol);
            assertEq(p.tickLower % p.tickSpacing, 0, p.symbol);
            assertEq(p.tickUpper % p.tickSpacing, 0, p.symbol);
            assertLt(p.tickLower, currentTick, p.symbol);
            assertLt(currentTick, p.tickUpper, p.symbol);
        }
    }

    function test_validate_acceptsTheFixture() public view {
        PoolEntry[] memory pools = PoolConfigLib.load(vm, FIXTURE);
        for (uint256 i = 0; i < pools.length; i++) {
            this.validateEntry(pools[i]);
        }
    }

    function test_validate_revertsOnAStaticFee() public {
        PoolEntry memory p = PoolConfigLib.load(vm, FIXTURE)[0];
        p.fee = 3000;
        vm.expectRevert(bytes("NVDA: fee must be the dynamic-fee flag 0x800000"));
        this.validateEntry(p);
    }

    function test_validate_revertsOnUnsortedOrEqualCurrencies() public {
        PoolEntry memory p = PoolConfigLib.load(vm, FIXTURE)[0];
        (p.currency0, p.currency1) = (p.currency1, p.currency0);
        vm.expectRevert(bytes("NVDA: currency0 must sort below currency1"));
        this.validateEntry(p);

        p.currency0 = p.currency1;
        vm.expectRevert(bytes("NVDA: currency0 must sort below currency1"));
        this.validateEntry(p);
    }

    /// @dev The mistake in the plan's sample entry: NVDA's stock paired through GOOGL's address
    function test_validate_revertsWhenThePairLacksTheStock() public {
        PoolEntry memory p = PoolConfigLib.load(vm, FIXTURE)[0];
        p.currency0 = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
        vm.expectRevert(bytes("NVDA: stock must be currency0 when stockIsCurrency0, else currency1"));
        this.validateEntry(p);
    }

    function test_initializePools_revertsOnAnotherChain() public {
        vm.chainId(1);
        InitIndexPoolsScript script = new InitIndexPoolsScript();
        vm.expectRevert(bytes("InitIndexPools: POOLS_JSON chainId != block.chainid: 4663 != 1"));
        script.initializePools(address(0xBEEF), FIXTURE);
    }

    function test_initializePools_revertsWithoutHookCode() public {
        vm.chainId(4663);
        InitIndexPoolsScript script = new InitIndexPoolsScript();
        vm.expectRevert(bytes("InitIndexPools: no code at HOOK_ADDRESS"));
        script.initializePools(address(0xBEEF), FIXTURE);
    }

    function validateEntry(PoolEntry memory p) external pure {
        PoolConfigLib.validate(p);
    }
}

/// @notice The mock answers the call exactly as BlockNumberish makes it
contract ArbSysMockTest is Test {
    function test_answersTheBlockNumberishCallWithTheBlockNumber() public {
        vm.etch(address(0x64), address(new ArbSysMock()).code);
        vm.roll(83_551_416);
        bool success;
        uint256 size;
        uint256 blockNumber;
        // BlockNumberish._getBlockNumberish: arbBlockNumber() selector, staticcall to 0x64, one 32-byte word back
        assembly ("memory-safe") {
            mstore(0x00, 0xa3b1b31d)
            success := staticcall(gas(), 0x64, 0x1c, 0x04, 0x00, 0x20)
            size := returndatasize()
            blockNumber := mload(0x00)
        }
        assertTrue(success);
        assertEq(size, 32);
        assertEq(blockNumber, block.number);
        assertEq(blockNumber, 83_551_416);
    }
}

/// @notice Runs the script against a real PoolManager and a hook that reads ArbSys, as the live 4663 hook does
contract InitIndexPoolsScriptTest is PoolsSampleFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    IPoolManager internal manager;
    StablePairHook internal hook;
    InitIndexPoolsScript internal script;
    bytes internal arbSysMockCode;

    function setUp() public {
        vm.chainId(4663);
        manager = new PoolManager(address(this));
        arbSysMockCode = address(new ArbSysMock()).code;
        // ArbSys answers when the hook is built on 4663, so its BlockNumberish caches _USE_ARB_SYS = true...
        vm.etch(ARB_SYS, arbSysMockCode);
        StablePairHook impl = new StablePairHook(manager);
        address proxy = address((type(uint160).max & ~Hooks.ALL_HOOK_MASK) | HOOK_FLAGS);
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (address(this), tx.origin, address(this)))
            ),
            proxy
        );
        hook = StablePairHook(proxy);
        // ...but a fork of 4663 holds only Nitro's placeholder byte there, which forge executes as INVALID
        vm.etch(ARB_SYS, hex"fe");
        script = new InitIndexPoolsScript();
    }

    /// @dev Why the script answers ArbSys itself: forge cannot otherwise execute initializePool on the live hook
    function test_hookCannotInitializeAgainstThePlaceholder() public {
        PoolEntry memory p = PoolConfigLib.load(vm, FIXTURE)[0];
        PoolKey memory key = _key(p);
        vm.prank(tx.origin);
        vm.expectRevert(bytes(""));
        hook.initializePool(key, p.sqrtPriceX96, p.feeConfig);

        vm.etch(ARB_SYS, arbSysMockCode);
        vm.prank(tx.origin);
        hook.initializePool(key, p.sqrtPriceX96, p.feeConfig);
    }

    function test_initializePools_initializesEveryPoolAtItsFixturePrice() public {
        string memory json = vm.readFile(FIXTURE);
        PoolEntry[] memory pools = PoolConfigLib.load(vm, FIXTURE);
        PoolId[] memory ids = script.initializePools(address(hook), FIXTURE);
        assertEq(ids.length, pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            _assertInitialized(pools[i], ids[i], _currentTick(json, i));
        }
    }

    function _assertInitialized(PoolEntry memory p, PoolId id, int24 currentTick) internal view {
        assertEq(PoolId.unwrap(id), PoolId.unwrap(_key(p).toId()), p.symbol);
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);
        assertEq(sqrtPriceX96, p.sqrtPriceX96, p.symbol);
        assertEq(tick, currentTick, p.symbol);
        (uint24 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 referenceSqrtPriceX96) = hook.feeConfig(id);
        assertEq(k, p.feeConfig.k, p.symbol);
        assertEq(optimalFeeE6, p.feeConfig.optimalFeeE6, p.symbol);
        assertEq(targetMultiplier, p.feeConfig.targetMultiplier, p.symbol);
        assertEq(referenceSqrtPriceX96, p.feeConfig.referenceSqrtPriceX96, p.symbol);
    }

    function _key(PoolEntry memory p) internal view returns (PoolKey memory) {
        return
            PoolKey(Currency.wrap(p.currency0), Currency.wrap(p.currency1), p.fee, p.tickSpacing, IHooks(address(hook)));
    }
}
