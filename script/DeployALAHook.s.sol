// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ALADynamicFeeHook} from "../src/ALADynamicFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DeployALAHook is Script {
    // Direcciones para Base Sepolia
    address constant POOL_MANAGER_BASE_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408; 
    address constant TRUSTED_SIGNER = 0x8481d7A4EC5096d34bf858d7ebA6FF743826609c;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Despliegue estándar del Hook (ahora funciona gracias a la modificación en BaseHook.sol)
        ALADynamicFeeHook hook = new ALADynamicFeeHook(IPoolManager(POOL_MANAGER_BASE_SEPOLIA), TRUSTED_SIGNER);
        
        console.log("ALA Dynamic Fee Hook desplegado en:", address(hook));
        console.log("Trusted Signer configurado:", TRUSTED_SIGNER);

        vm.stopBroadcast();
    }
}
