// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ALADynamicFeeHook} from "../src/ALADynamicFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DeployALAHook is Script {
    // Direcciones hardcodeadas para Base Sepolia (por compatibilidad con scripts viejos)
    // Se sobrescriben si la red es ETH Sepolia o si se provee variable de entorno.
    address constant POOL_MANAGER_BASE_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant POOL_MANAGER_ETH_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    
    address constant TRUSTED_SIGNER = 0x8481d7A4EC5096d34bf858d7ebA6FF743826609c;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address poolManager = _getPoolManager();
        
        // Despliegue estándar del Hook (Nota: Para producción real se debería usar HookMiner para obtener flags)
        // Por ahora mantenemos la simplicidad, pero ten en cuenta que el PoolManager validará flags.
        // Si este script es para producción, debería minar la dirección.
        // Asumimos que para este hackathon, usaremos el script de TestRehypothecation que sí mina.
        // Pero si el usuario quiere desplegar solo el Hook...
        // Vamos a pasar los argumentos nuevos.
        
        address platformAddr = vm.addr(deployerPrivateKey);
        address govToken = address(0); // TODO: Setear token real
        
        ALADynamicFeeHook hook = new ALADynamicFeeHook(IPoolManager(poolManager), TRUSTED_SIGNER, TRUSTED_SIGNER, platformAddr, govToken);
        
        console.log("ALA Dynamic Fee Hook desplegado en:", address(hook));
        console.log("PoolManager usado:", poolManager);
        console.log("Trusted Signer (y Data Scientist):", TRUSTED_SIGNER);
        console.log("Platform Beneficiary:", platformAddr);

        vm.stopBroadcast();
    }

    function _getPoolManager() internal view returns (address) {
        // 1. Intentar variable de entorno
        try vm.envAddress("POOL_MANAGER_ADDRESS") returns (address addr) {
            if (addr != address(0)) return addr;
        } catch {}

        // 2. Detectar red por ChainID
        if (block.chainid == 11155111) { // Sepolia ETH
            return POOL_MANAGER_ETH_SEPOLIA;
        } else if (block.chainid == 84532) { // Base Sepolia
            return POOL_MANAGER_BASE_SEPOLIA;
        }

        // 3. Default a Base Sepolia si no se sabe
        return POOL_MANAGER_BASE_SEPOLIA;
    }
}
