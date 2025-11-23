// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {ALADynamicFeeHook} from "../src/ALADynamicFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Mina un address compatible y despliega el hook con CREATE2.
contract MineAndDeployALAHook is Script {
    // Base Sepolia
    address constant POOL_MANAGER_BASE_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant TRUSTED_SIGNER = 0x8481d7A4EC5096d34bf858d7ebA6FF743826609c;

    function run() external {
        // Solo necesitamos BEFORE_SWAP para este hook
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER_BASE_SEPOLIA), TRUSTED_SIGNER);

        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(ALADynamicFeeHook).creationCode, constructorArgs);

        console.log("Hook address minada (esperada):", expected);
        console.log("Salt encontrada:", vm.toString(salt));

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        ALADynamicFeeHook hook =
            new ALADynamicFeeHook{salt: salt}(IPoolManager(POOL_MANAGER_BASE_SEPOLIA), TRUSTED_SIGNER);
        vm.stopBroadcast();

        require(address(hook) == expected, "Hook address mismatch");
        console.log("Hook desplegado en:", address(hook));
    }
}
