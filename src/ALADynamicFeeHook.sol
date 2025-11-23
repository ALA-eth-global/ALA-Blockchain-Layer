// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

// Interface minima necesaria para interactuar con el Vault
interface IERC4626 is IERC20 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256);
}

import {console} from "forge-std/console.sol"; // Importar console

contract ALADynamicFeeHook is BaseHook {
    using LPFeeLibrary for uint24;
    using ECDSA for bytes32;
    using CurrencyLibrary for Currency;
    using SafeCast for int128;
    using SafeCast for uint256;
    using BalanceDeltaLibrary for BalanceDelta;

    // La dirección pública de tu Backend (ALA Router)
    address public immutable TRUSTED_SIGNER;
    address public immutable DATA_SCIENTIST;
    address public immutable PLATFORM;
    IERC20 public immutable GOVERNANCE_TOKEN; // Token $ALA

    // --- VARIABLES DE REHYPOTHECATION ---
    mapping(Currency => IERC4626) public vaults;
    mapping(address => mapping(Currency => uint256)) public accumulatedFees;

    // Configuraciones DEFAULT (si no se proveen o para addLiquidity)
    uint256 public constant DEFAULT_BUFFER = 15;
    uint256 public constant DEFAULT_LOWER = 5;
    uint256 public constant DEFAULT_UPPER = 25;
    uint256 public constant MIN_SWAP_THRESHOLD = 1 ether;
    
    uint256 public constant FIXED_HOOK_FEE_BPS = 6; // 0.06% Total (Standard)
    uint256 public constant DISCOUNTED_HOOK_FEE_BPS = 3; // 0.03% Total (VIP)
    uint256 public constant VIP_THRESHOLD = 100 ether; // 100 ALA tokens para ser VIP

    error InvalidSignature();
    error ExpiredSignature();
    error HookFeeTooLarge();

    constructor(IPoolManager _poolManager, address _signer, address _ds, address _platform, address _govToken) BaseHook(_poolManager) {
        TRUSTED_SIGNER = _signer;
        DATA_SCIENTIST = _ds;
        PLATFORM = _platform;
        GOVERNANCE_TOKEN = IERC20(_govToken);
    }

    function setVault(Currency currency, address _vault) external {
        vaults[currency] = IERC4626(_vault);
        IERC20(Currency.unwrap(currency)).approve(_vault, type(uint256).max);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    struct FeeData {
        uint24 newFee;
        uint8 targetBuffer;
        uint8 lowerBound;
        uint8 upperBound;
        uint256 deadline;
        bytes signature;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        
        FeeData memory data = abi.decode(hookData, (FeeData));
        if (block.timestamp > data.deadline) revert ExpiredSignature();

        bytes32 messageHash = keccak256(abi.encodePacked(
            key.toId(),
            data.newFee,
            data.targetBuffer,
            data.lowerBound,
            data.upperBound,
            data.deadline,
            block.chainid
        ));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        if (ethSignedMessageHash.recover(data.signature) != TRUSTED_SIGNER) revert InvalidSignature();

        // Rebalance check using DYNAMIC params
        _checkRebalance(key.currency0, data.targetBuffer, data.lowerBound, data.upperBound);
        _checkRebalance(key.currency1, data.targetBuffer, data.lowerBound, data.upperBound);

        uint24 feeWithFlag = data.newFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (ALADynamicFeeHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        // En afterSwap volvemos a chequear, pero necesitamos los params.
        // Decodificamos hookData de nuevo para mantener consistencia
        FeeData memory data = abi.decode(hookData, (FeeData));
        _checkRebalance(key.currency0, data.targetBuffer, data.lowerBound, data.upperBound);
        _checkRebalance(key.currency1, data.targetBuffer, data.lowerBound, data.upperBound);

        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        if (unspecifiedAmount > 0) {
             // Verificar si es VIP ($ALA Holder)
             uint256 feeBps = FIXED_HOOK_FEE_BPS;
             
             if (address(GOVERNANCE_TOKEN) != address(0)) {
                 // Usamos tx.origin para simplificar la demo
                 if (GOVERNANCE_TOKEN.balanceOf(tx.origin) >= VIP_THRESHOLD) {
                     feeBps = DISCOUNTED_HOOK_FEE_BPS;
                     console.log("DEBUG Hook: VIP Detectado! Fee reducido a 0.03%");
                 }
             }

             uint256 feeAmount = FullMath.mulDiv(uint256(int256(unspecifiedAmount)), feeBps, 10000);
             console.log("DEBUG Hook: Fee calculado:", feeAmount);
             
             if (feeAmount > 0) {
                 poolManager.take(unspecified, address(this), feeAmount);
                 // El Hook DEBE hacer take() porque al retornar feeAmount, el PoolManager le asigna ese saldo a favor al Hook.
                 // Si no lo sacamos, queda un delta positivo sin reclamar -> CurrencyNotSettled.
                 
                 _settleFee(unspecified, feeAmount);
                 return (this.afterSwap.selector, feeAmount.toInt128());
             }
        }
        return (this.afterSwap.selector, 0);
    }

    function _settleFee(Currency currency, uint256 amount) internal {
        // Total Fee es 0.06% (6 BPS)
        // Plataforma lleva 0.01% (1 BPS) -> 1/6 del total
        // Data Scientist lleva 0.05% (5 BPS) -> 5/6 del total
        
        uint256 platformAmount = amount / 6; 
        uint256 dsAmount = amount - platformAmount; // El resto para DS para evitar residuos
        
        accumulatedFees[PLATFORM][currency] += platformAmount;
        accumulatedFees[DATA_SCIENTIST][currency] += dsAmount;
    }

    function claimFees(Currency currency) external {
        uint256 amount = accumulatedFees[msg.sender][currency];
        if (amount > 0) {
            accumulatedFees[msg.sender][currency] = 0;
            IERC20(Currency.unwrap(currency)).transfer(msg.sender, amount);
        }
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        // En addLiquidity no solemos tener hookData con firma dinamica fresca.
        // Usamos defaults.
        _checkRebalance(key.currency0, DEFAULT_BUFFER, DEFAULT_LOWER, DEFAULT_UPPER);
        _checkRebalance(key.currency1, DEFAULT_BUFFER, DEFAULT_LOWER, DEFAULT_UPPER);
        return ALADynamicFeeHook.beforeAddLiquidity.selector;
    }

    function _checkRebalance(Currency currency, uint256 targetBuffer, uint256 lowerBound, uint256 upperBound) internal {
        IERC4626 vault = vaults[currency];
        if (address(vault) == address(0)) return;

        IERC20 token = IERC20(Currency.unwrap(currency));
        
        uint256 balanceInHook = token.balanceOf(address(this));
        uint256 balanceInVault = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 totalLiquidity = balanceInHook + balanceInVault;

        if (totalLiquidity == 0) return;

        uint256 currentBufferPercent = (balanceInHook * 100) / totalLiquidity;

        if (currentBufferPercent < lowerBound) {
            uint256 targetHookBalance = (totalLiquidity * targetBuffer) / 100;
            if (targetHookBalance > balanceInHook) {
                uint256 amountToWithdraw = targetHookBalance - balanceInHook;
                if (balanceInVault >= amountToWithdraw) {
                    vault.withdraw(amountToWithdraw, address(this), address(this));
                }
            }

        } else if (currentBufferPercent > upperBound) {
            uint256 targetHookBalance = (totalLiquidity * targetBuffer) / 100;
            if (balanceInHook > targetHookBalance) {
                uint256 amountToDeposit = balanceInHook - targetHookBalance;
                vault.deposit(amountToDeposit, address(this));
            }
        }
    }
}
