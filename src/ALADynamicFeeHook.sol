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
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

// Interface minima necesaria para interactuar con el Vault
interface IERC4626 is IERC20 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256);
}

contract ALADynamicFeeHook is BaseHook {
    using LPFeeLibrary for uint24;
    using ECDSA for bytes32;
    using CurrencyLibrary for Currency;

    // La dirección pública de tu Backend (ALA Router)
    address public immutable TRUSTED_SIGNER;

    // --- VARIABLES DE REHYPOTHECATION ---
    mapping(Currency => IERC4626) public vaults;

    // Configuraciones de Estrategia (15% Buffer, rebalancear si <5% o >25%)
    uint256 public constant TARGET_BUFFER_PERCENT = 15; 
    uint256 public constant LOWER_BOUND_PERCENT = 5;
    uint256 public constant UPPER_BOUND_PERCENT = 25;
    uint256 public constant MIN_SWAP_THRESHOLD = 1 ether; 

    error InvalidSignature();
    error ExpiredSignature();

    constructor(IPoolManager _poolManager, address _signer) BaseHook(_poolManager) {
        TRUSTED_SIGNER = _signer;
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
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    struct FeeData {
        uint24 newFee;
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
            data.deadline,
            block.chainid
        ));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        if (ethSignedMessageHash.recover(data.signature) != TRUSTED_SIGNER) revert InvalidSignature();

        // Rebalance check using only currency (safe)
        _checkRebalance(key.currency0);
        _checkRebalance(key.currency1);

        uint24 feeWithFlag = data.newFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (ALADynamicFeeHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        _checkRebalance(key.currency0);
        _checkRebalance(key.currency1);
        return (ALADynamicFeeHook.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        _checkRebalance(key.currency0);
        _checkRebalance(key.currency1);
        return ALADynamicFeeHook.beforeAddLiquidity.selector;
    }

    function _checkRebalance(Currency currency) internal {
        IERC4626 vault = vaults[currency];
        if (address(vault) == address(0)) return;

        IERC20 token = IERC20(Currency.unwrap(currency));
        
        uint256 balanceInHook = token.balanceOf(address(this));
        // Use staticcall to be safe or just call view function
        uint256 balanceInVault = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 totalLiquidity = balanceInHook + balanceInVault;

        if (totalLiquidity == 0) return;

        uint256 currentBufferPercent = (balanceInHook * 100) / totalLiquidity;

        if (currentBufferPercent < LOWER_BOUND_PERCENT) {
            uint256 targetHookBalance = (totalLiquidity * TARGET_BUFFER_PERCENT) / 100;
            if (targetHookBalance > balanceInHook) {
                uint256 amountToWithdraw = targetHookBalance - balanceInHook;
                if (balanceInVault >= amountToWithdraw) {
                    vault.withdraw(amountToWithdraw, address(this), address(this));
                }
            }

        } else if (currentBufferPercent > UPPER_BOUND_PERCENT) {
            uint256 targetHookBalance = (totalLiquidity * TARGET_BUFFER_PERCENT) / 100;
            if (balanceInHook > targetHookBalance) {
                uint256 amountToDeposit = balanceInHook - targetHookBalance;
                vault.deposit(amountToDeposit, address(this));
            }
        }
    }
}
