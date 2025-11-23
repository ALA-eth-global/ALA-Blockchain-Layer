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

contract TestHook is Script, StdCheats {
    using PoolIdLibrary for PoolKey;

    // --- CONFIGURACIÓN PARA BASE SEPOLIA ---
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);

    // Dirección del Signer que configuraste en el Hook
    address constant TRUSTED_SIGNER = 0x8481d7A4EC5096d34bf858d7ebA6FF743826609c;

    // Tokens (defaults, override via env WETH_ADDRESS / USDC_ADDRESS)
    address constant DEFAULT_WETH = 0x4200000000000000000000000000000000000006;
    address constant DEFAULT_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint160 constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740; // TickMath.MIN_SQRT_PRICE + 1

    struct RunConfig {
        IERC20 token0;
        IERC20 token1;
        uint256 amount0;
        uint256 amount1;
        uint256 liquidityDelta;
        uint256 swapAmountIn;
    }

    function run() external {
        // --- 1. CONFIGURACIÓN DE WALLETS ---
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address hookAddress = vm.envAddress("ALA_HOOK_ADDRESS");

        // Tokens y montos configurables vía env
        // Por defecto usamos direcciones de Base Sepolia, pero si detectamos SIMULATION=true
        // se reemplazarán por Mocks creados al vuelo.
        IERC20 weth = IERC20(_envAddressOr("WETH_ADDRESS", DEFAULT_WETH));
        IERC20 usdc = IERC20(_envAddressOr("USDC_ADDRESS", DEFAULT_USDC));
        
        // Defaults muy pequeños para evitar problemas de balance si no usamos Mocks
        uint256 wethAmount = _envUintOr("WETH_AMOUNT", 1e15); // 0.001 WETH
        uint256 usdcAmount = _envUintOr("USDC_AMOUNT", 1_000_000); // 1 USDC (6 dec)
        uint256 liquidityDelta = _envUintOr("LIQUIDITY_DELTA", 1_000); // 
        uint256 swapAmountIn = _envUintOr("SWAP_AMOUNT_IN", 1_000); // amountSpecified será -swapAmountIn

        // --- ESTRATEGIA DE MOCKS PARA SIMULACIÓN ---
        // Si la variable de entorno SIMULATION=true está presente, ignoramos los tokens reales (y sus Proxies)
        // y desplegamos tokens MockERC20 limpios. Esto soluciona el error de `deal` con Proxies de USDC.
        bool useDeal = _shouldUseDeal();
        if (useDeal) {
             vm.startBroadcast(deployerPrivateKey);
            // Deploy Mock Tokens
            MockERC20 mock0 = new MockERC20("Mock WETH", "mWETH", 18);
            MockERC20 mock1 = new MockERC20("Mock USDC", "mUSDC", 6);
            weth = IERC20(address(mock0));
            usdc = IERC20(address(mock1));
            console.log("Simulacion ACTIVA: Usando Mock Tokens para evitar errores de Proxy.");
            console.log("Mock WETH:", address(weth));
            console.log("Mock USDC:", address(usdc));
             vm.stopBroadcast();
        }

        RunConfig memory cfg = _orderedConfig(weth, usdc, wethAmount, usdcAmount, liquidityDelta, swapAmountIn);

        // Preparamos el pool y los datos del hook
        (PoolKey memory poolKey, , bytes memory hookData) =
            _preparePoolAndHookData(deployerPrivateKey, hookAddress, cfg.token0, cfg.token1);

        // Ejecutar agregar liquidez + swap vía unlock callback
        vm.startBroadcast(deployerPrivateKey);
        PoolExecutor executor = new PoolExecutor(POOL_MANAGER, cfg.token0, cfg.token1);
        vm.stopBroadcast();

        if (useDeal) {
            // Usamos mint en lugar de deal para MockTokens, es más seguro y 100% compatible
            vm.startBroadcast(deployerPrivateKey);
            MockERC20(address(cfg.token0)).mint(address(executor), cfg.amount0);
            MockERC20(address(cfg.token1)).mint(address(executor), cfg.amount1);
            vm.stopBroadcast();
            
            console.log("Simulacion: Fondos 'minteados' al Executor exitosamente.");
            console.log("Balance Executor Token0:", cfg.token0.balanceOf(address(executor)));
            console.log("Balance Executor Token1:", cfg.token1.balanceOf(address(executor)));
        } else {
            // En broadcast real, transferimos fondos desde la wallet del deployer
            vm.startBroadcast(deployerPrivateKey);
            cfg.token0.transfer(address(executor), cfg.amount0);
            cfg.token1.transfer(address(executor), cfg.amount1);
            vm.stopBroadcast();
            console.log("Broadcast Real: Fondos transferidos al Executor desde deployer.");
        }

        vm.startBroadcast(deployerPrivateKey);
        executor.approveMax();

        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: -210060, // múltiplos de 60 para tickSpacing=60
            tickUpper: -189960,
            liquidityDelta: int256(cfg.liquidityDelta),
            salt: bytes32(0)
        });

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(cfg.swapAmountIn),
            sqrtPriceLimitX96: MIN_SQRT_PRICE_PLUS_ONE
        });

        executor.unlockAndRun(
            PoolExecutor.Params({poolKey: poolKey, liqParams: liqParams, swapParams: swapParams, hookData: hookData})
        );
        console.log("Liquidez agregada y swap ejecutado via unlock.");
        vm.stopBroadcast();
    }

    function _orderedConfig(
        IERC20 weth,
        IERC20 usdc,
        uint256 wethAmount,
        uint256 usdcAmount,
        uint256 liquidityDelta,
        uint256 swapAmountIn
    ) internal pure returns (RunConfig memory cfg) {
        cfg.token0 = weth;
        cfg.token1 = usdc;
        cfg.amount0 = wethAmount;
        cfg.amount1 = usdcAmount;
        cfg.liquidityDelta = liquidityDelta;
        cfg.swapAmountIn = swapAmountIn;

        if (address(weth) > address(usdc)) {
            (cfg.token0, cfg.token1) = (cfg.token1, cfg.token0);
            (cfg.amount0, cfg.amount1) = (cfg.amount1, cfg.amount0);
        }
    }

    function _preparePoolAndHookData(
        uint256 deployerPrivateKey,
        address hookAddress,
        IERC20 token0,
        IERC20 token1
    ) internal returns (PoolKey memory poolKey, bytes32 poolIdBytes, bytes memory hookData) {
        (poolKey, poolIdBytes) = _createPool(deployerPrivateKey, hookAddress, token0, token1);
        hookData = _buildHookData(poolIdBytes);
    }

    function _createPool(uint256 deployerPrivateKey, address hookAddress, IERC20 token0, IERC20 token1)
        internal
        returns (PoolKey memory poolKey, bytes32 poolIdBytes)
    {
        // --- 2. CREAR Y FINANCIAR EL POOL ---
        // Asegurarse de que los tokens esten ordenados por direccion para la PoolKey
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        // Configuracion inicial del pool
        // Pool de fee dinámico: usa la bandera DYNAMIC_FEE_FLAG para permitir override vía hook
        uint24 poolFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        int24 tickSpacing = 60;
        poolKey = PoolKey(currency0, currency1, poolFee, tickSpacing, IHooks(hookAddress));
        PoolId poolId = poolKey.toId();
        poolIdBytes = PoolId.unwrap(poolId);

        // Precio inicial: 1 WETH = 2000 USDC
        uint160 sqrtPriceX96 = 5602277097478614198912276234240;

        vm.startBroadcast(deployerPrivateKey);

        // Crear el pool a traves del PoolManager
        POOL_MANAGER.initialize(poolKey, sqrtPriceX96);
        console.log("Pool Creado. ID:");
        console.logBytes32(poolIdBytes);

        vm.stopBroadcast();
    }

    function _buildHookData(bytes32 poolIdBytes) internal returns (bytes memory hookData) {
        // --- 3. SIMULAR EL BACKEND Y FIRMAR EL FEE ---
        uint24 dynamicFee = 10000; // 1%
        uint256 deadline = block.timestamp + 60;
        uint256 trustedSignerPrivateKey = vm.envUint("TRUSTED_SIGNER_PRIVATE_KEY");

        // Construir el hash del mensaje (debe ser identico al del hook!)
        bytes32 messageHash = keccak256(abi.encodePacked(poolIdBytes, dynamicFee, deadline, block.chainid));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        // Firmar el hash con la clave privada del signer
        bytes memory signature = _signDigest(ethSignedMessageHash, trustedSignerPrivateKey);

        // Formatear el hookData
        ALADynamicFeeHook.FeeData memory feeData = ALADynamicFeeHook.FeeData(dynamicFee, deadline, signature);
        hookData = abi.encode(feeData);

        console.log("Fee Dinamico Firmado:", dynamicFee);
        console.log("hookData generado:", vm.toString(hookData));
    }

    function _signDigest(bytes32 digest, uint256 signerPrivateKey) internal view returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _shouldUseDeal() internal view returns (bool) {
        // Si no existe la variable de entorno, asumimos false (modo broadcast real)
        try vm.envBool("SIMULATION") returns (bool val) {
            return val;
        } catch {
            return false;
        }
    }

    function _envAddressOr(string memory key, address defaultVal) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            return val;
        } catch {
            return defaultVal;
        }
    }

    function _envUintOr(string memory key, uint256 defaultVal) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 val) {
            return val;
        } catch {
            return defaultVal;
        }
    }
}

/// @notice Ejecuta modifyLiquidity y swap dentro de unlockCallback del PoolManager.
contract PoolExecutor is IUnlockCallback {
    IPoolManager public immutable poolManager;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    Currency public immutable currency0;
    Currency public immutable currency1;

    struct Params {
        PoolKey poolKey;
        ModifyLiquidityParams liqParams;
        SwapParams swapParams;
        bytes hookData;
    }

    constructor(IPoolManager _poolManager, IERC20 _token0, IERC20 _token1) {
        poolManager = _poolManager;
        token0 = _token0;
        token1 = _token1;
        currency0 = Currency.wrap(address(_token0));
        currency1 = Currency.wrap(address(_token1));
    }

    function approveMax() external {
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
    }

    function unlockAndRun(Params calldata params) external {
        poolManager.unlock(abi.encode(params));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not poolManager");

        Params memory params = abi.decode(data, (Params));
        (BalanceDelta liqDelta,) = poolManager.modifyLiquidity(params.poolKey, params.liqParams, bytes(""));
        BalanceDelta swapDelta = poolManager.swap(params.poolKey, params.swapParams, params.hookData);
        BalanceDelta total = liqDelta + swapDelta;
        _settle(total);
        return bytes("");
    }

    function _settle(BalanceDelta delta) internal {
        int128 amt0 = delta.amount0();
        int128 amt1 = delta.amount1();

        if (amt0 < 0) {
            _pay(currency0, token0, uint128(-amt0));
        }
        if (amt1 < 0) {
            _pay(currency1, token1, uint128(-amt1));
        }

        if (amt0 > 0) {
            poolManager.take(currency0, address(this), uint128(amt0));
        }
        if (amt1 > 0) {
            poolManager.take(currency1, address(this), uint128(amt1));
        }
    }

    function _pay(Currency currency, IERC20 token, uint256 amount) internal {
        poolManager.sync(currency);
        token.transfer(address(poolManager), amount);
        poolManager.settle();
    }
}
