
## 7. Guía para ETH Sepolia (Nueva Red)

El proyecto soporta despliegue tanto en **Base Sepolia** como en **Ethereum Sepolia**.

### Pasos para ETH Sepolia:

1.  **Configura tu .env:**
    `ini
    RPC_URL=https://rpc.sepolia.org
    SIMULATION=false  # Para usar tokens reales (WETH/USDC)
    ` 

2.  **Despliega el Hook:**
    `ash
    source .env
    forge script script/DeployALAHook.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv
    ` 
    *El script detectará automáticamente el ChainID y usará el PoolManager oficial de Sepolia.*

3.  **Actualiza el Hook:**
    Copia la dirección del contrato desplegado y actualiza ALA_HOOK_ADDRESS en tu .env.

4.  **Prueba un Swap:**
    `ash
    forge script script/TestHook.s.sol --tc TestHook --rpc-url $RPC_URL --broadcast -vvvv
    ` 
    *Nota: Necesitas tener WETH y USDC de Sepolia en tu wallet para este paso.*

---

**Hackathon 2025 - ALA Team**
