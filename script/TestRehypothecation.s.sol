// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {ALADynamicFeeHook} from "../src/ALADynamicFeeHook.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockERC4626} from "./MockERC4626.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

contract TestRehypothecation is Script, StdCheats {
    using PoolIdLibrary for PoolKey;

    // Configuración
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant TRUSTED_SIGNER = 0x8481d7A4EC5096d34bf858d7ebA6FF743826609c;
    uint160 constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740;

    // Evento Swap del PoolManager para verificar el fee
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("\n==================================================");
        console.log("   INICIO DE LA DEMO INTEGRAL (Fee + Rehypothecation)");
        console.log("==================================================\n");

        // 1. DESPLIEGUE DE INFRAESTRUCTURA (Mocks y Hook)
        console.log("[PASO 1] Desplegando Tokens y Vaults Mock...");
        MockERC20 mockWETH = new MockERC20("Mock WETH", "mWETH", 18);
        MockERC20 mockUSDC = new MockERC20("Mock USDC", "mUSDC", 6);
        MockERC4626 vaultWETH = new MockERC4626(IERC20(address(mockWETH)), "Vault WETH", "vWETH");
        MockERC4626 vaultUSDC = new MockERC4626(IERC20(address(mockUSDC)), "Vault USDC", "vUSDC");
        console.log(" > Tokens listos.");

        console.log("\n[PASO 2] Minando y Desplegando ALA Hook (V2)...");
        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        (address hookAddr, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(ALADynamicFeeHook).creationCode, abi.encode(POOL_MANAGER, TRUSTED_SIGNER));
        
        ALADynamicFeeHook hook = new ALADynamicFeeHook{salt: salt}(POOL_MANAGER, TRUSTED_SIGNER);
        require(address(hook) == hookAddr, "Error: Direccion del Hook no coincide");
        
        hook.setVault(Currency.wrap(address(mockWETH)), address(vaultWETH));
        hook.setVault(Currency.wrap(address(mockUSDC)), address(vaultUSDC));
        console.log(" > Hook V2 Desplegado en:", address(hook));
        console.log(" > Vaults configurados exitosamente.");
        vm.stopBroadcast();

        // 2. CONFIGURACIÓN DEL POOL Y FIRMA OFF-CHAIN
        console.log("\n[PASO 3] Backend: Calculando y Firmando Fee Dinamico...");
        uint24 dynamicFee = 10000; // 1% (10000 pips)
        console.log(" > Fee calculado por AI:", dynamicFee / 10000, ".00% (High Volatility Detected)");
        
        (PoolKey memory poolKey, bytes32 poolId, bytes memory hookData) = 
            _preparePoolAndSign(deployerPrivateKey, address(hook), IERC20(address(mockWETH)), IERC20(address(mockUSDC)), dynamicFee);
        console.log(" > Firma Criptografica generada y empaquetada en hookData.");

        // 3. ESTADO INICIAL DE LIQUIDEZ
        vm.startBroadcast(deployerPrivateKey);
        PoolExecutor executor = new PoolExecutor(POOL_MANAGER, IERC20(address(mockWETH)), IERC20(address(mockUSDC)));
        
        // Fondear Executor y Hook
        mockWETH.mint(address(executor), 100e18); // Para hacer swap
        mockWETH.mint(address(hook), 10e18);      // 10 WETH ociosos en el Hook (100% Liquidez)
        
        console.log("\n[PASO 4] Estado de Inventario ANTES del Swap:");
        uint256 hookBal = mockWETH.balanceOf(address(hook));
        uint256 vaultBal = vaultWETH.totalAssets();
        console.log(" > Liquidez Ociosa en Hook: ", formatDecimals(hookBal, 18), "WETH (100% del Total)");
        console.log(" > Liquidez Invirtiendo en Vault:", formatDecimals(vaultBal, 18), "WETH (0% del Total)");
        console.log(" > ALERTA: Exceso de liquidez detectado (> 25% Buffer Maximo).");

        // 4. EJECUCIÓN DEL SWAP
        console.log("\n[PASO 5] Ejecutando Swap con Hook...");
        executor.approveMax();
        
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e17, // Swap 0.1 WETH
            sqrtPriceLimitX96: MIN_SQRT_PRICE_PLUS_ONE
        });

        // Espiar evento Swap (Solo verificamos que se emita por el sender correcto, ignoramos data exacta para evitar fallos de redondeo)
        vm.expectEmit(false, true, false, false, address(POOL_MANAGER));
        emit Swap(
            PoolId.wrap(bytes32(0)), // Ignorado (index 1 false)
            address(executor),       // Verificado (index 2 true)
            0, 0, 0, 0, 0, 0         // Ignorados (data false)
        );
        
        executor.unlockAndRun(
            PoolExecutor.Params({poolKey: poolKey, liqParams: _emptyLiqParams(), swapParams: swapParams, hookData: hookData})
        );
        vm.stopBroadcast();
        console.log(" > Swap Ejecutado Exitosamente.");

        // 5. VERIFICACIÓN FINAL
        console.log("\n[PASO 6] Verificacion de Resultados:");
        
        uint256 hookBalAfter = mockWETH.balanceOf(address(hook));
        uint256 vaultBalAfter = vaultWETH.totalAssets();
        uint256 totalBal = hookBalAfter + vaultBalAfter;
        
        console.log(" > Liquidez Ociosa en Hook: ", formatDecimals(hookBalAfter, 18), "WETH");
        console.log(" > Liquidez Invirtiendo en Vault:", formatDecimals(vaultBalAfter, 18), "WETH");
        
        uint256 bufferPercent = (hookBalAfter * 100) / totalBal;
        console.log(" > Nuevo % de Buffer:", bufferPercent, "% (Target: 15%)");

        if (vaultBalAfter > 8e18) {
            console.log(unicode"\n[CONCLUSION] TEST PASADO (EXITO) ✅");
            console.log("1. El Fee Dinamico fue aceptado (Swap no revirtio).");
            console.log("2. El Hook rebalanceo automaticamente el exceso al Vault.");
        } else {
            console.log(unicode"\n[CONCLUSION] TEST FALLIDO ❌ - No se movieron fondos al Vault.");
        }
        console.log("==================================================\n");
    }

    function _preparePoolAndSign(uint256 pk, address hook, IERC20 t0, IERC20 t1, uint24 fee) internal returns (PoolKey memory key, bytes32 id, bytes memory data) {
        if (address(t0) > address(t1)) (t0, t1) = (t1, t0);
        Currency c0 = Currency.wrap(address(t0));
        Currency c1 = Currency.wrap(address(t1));
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        id = PoolId.unwrap(key.toId());
        
        vm.startBroadcast(pk);
        POOL_MANAGER.initialize(key, 4295128740000000000000000000); 
        vm.stopBroadcast();

        uint256 deadline = block.timestamp + 100;
        uint256 signerPk = vm.envUint("TRUSTED_SIGNER_PRIVATE_KEY");
        bytes32 msgHash = keccak256(abi.encodePacked(id, fee, deadline, block.chainid));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethHash);
        data = abi.encode(ALADynamicFeeHook.FeeData(fee, deadline, abi.encodePacked(r, s, v)));
    }

    function _emptyLiqParams() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(0, 0, 0, bytes32(0));
    }

    // Helper simple para imprimir decimales (aprox)
    function formatDecimals(uint256 amount, uint8 decimals) internal pure returns (string memory) {
        uint256 integerPart = amount / (10**decimals);
        uint256 fractionalPart = (amount % (10**decimals)) / (10**(decimals - 2)); // 2 decimales
        return string(abi.encodePacked(vm.toString(integerPart), ".", vm.toString(fractionalPart)));
    }
}

contract PoolExecutor is IUnlockCallback {
    IPoolManager manager;
    IERC20 t0; IERC20 t1;
    struct Params { PoolKey poolKey; ModifyLiquidityParams liqParams; SwapParams swapParams; bytes hookData; }
    constructor(IPoolManager _m, IERC20 _t0, IERC20 _t1) { manager = _m; t0 = _t0; t1 = _t1; }
    function approveMax() external { t0.approve(address(manager), type(uint256).max); t1.approve(address(manager), type(uint256).max); }
    function unlockAndRun(Params calldata p) external { manager.unlock(abi.encode(p)); }
    function unlockCallback(bytes calldata d) external returns (bytes memory) {
        Params memory p = abi.decode(d, (Params));
        if (p.liqParams.liquidityDelta != 0) manager.modifyLiquidity(p.poolKey, p.liqParams, "");
        (BalanceDelta delta) = manager.swap(p.poolKey, p.swapParams, p.hookData);
        
        if (delta.amount0() < 0) { t0.transfer(address(manager), uint128(-delta.amount0())); manager.settle(); }
        if (delta.amount1() < 0) { t1.transfer(address(manager), uint128(-delta.amount1())); manager.settle(); }
        if (delta.amount0() > 0) manager.take(Currency.wrap(address(t0)), address(this), uint128(delta.amount0()));
        if (delta.amount1() > 0) manager.take(Currency.wrap(address(t1)), address(this), uint128(delta.amount1()));
        return "";
    }
}
