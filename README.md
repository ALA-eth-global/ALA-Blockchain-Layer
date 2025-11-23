# ALA Pool - Hook de AMM con Tarifas Dinámicas

## 1. Visión y Problema

Los Automated Market Makers (AMMs) tradicionales usan un modelo de comisiones (fees) estáticas (ej. 0.3%, 0.05%). Este modelo es ineficiente:
- **En Mercados Volátiles:** Los proveedores de liquidez (LPs) sufren un mayor Impermanent Loss (IL) que no es compensado adecuadamente por las comisiones.
- **En Mercados Estables:** Las comisiones pueden ser demasiado altas, resultando en un peor precio para los traders en comparación con otros pools.

**ALA Pool** soluciona esto introduciendo un **Hook de Uniswap V4** que permite a un oráculo off-chain ajustar las comisiones de swap en tiempo real, basándose en las condiciones del mercado.

---

## 2. Arquitectura y Concepto

El sistema se compone de tres capas que trabajan en conjunto:

```
      +-----------------------------+
      |      1. Capa de Datos       |
      | (Off-Chain: ALA DATA)       |
      +-----------------------------+
                 |
                 v
      +-----------------------------+
      |    2. Capa de Ejecución     |
      | (Off-Chain: ALA ROUTER)     |
      +-----------------------------+
                 |
                 v
      +-----------------------------+
      |      3. Capa de Contratos   |
      |  (On-Chain: ALA POOL Hook)  |
      +-----------------------------+
```

1.  **Capa de Datos (El Cerebro):**
    *   Un modelo de Data Science (DS Model) analiza datos de mercado (ej. volatilidad histórica, desequilibrio del pool) para determinar la comisión óptima.
    *   Se utiliza una **función sigmoide** para mapear el riesgo a una comisión: a bajo riesgo, la comisión es mínima; a alto riesgo, la comisión aumenta rápidamente hasta un tope máximo predefinido.

2.  **Capa de Ejecución (El Mensajero Seguro):**
    *   Este es el backend/oráculo que toma la comisión calculada por el modelo.
    *   Usa una clave privada segura (`TRUSTED_SIGNER`) para generar una **firma criptográfica** que autoriza el cambio de comisión.
    *   Esta firma, junto con el fee y un deadline, se empaqueta en un payload (`hookData`).
    *   Expone una API para que el frontend obtenga este `hookData` justo antes de un swap.

3.  **Capa de Contratos (El Guardia de Seguridad On-Chain):**
    *   Nuestro `ALADynamicFeeHook.sol` es un hook de Uniswap V4 que se activa en la función `beforeSwap`.
    *   Recibe el `hookData` y verifica la autenticidad de la firma usando `ECDSA.recover`.
    *   Si la firma es válida y proviene del `TRUSTED_SIGNER`, el hook instruye al PoolManager de Uniswap V4 para que aplique la comisión dinámica a ese swap específico. Si no, la transacción se revierte.

---

## 3. Guía Técnica

### Prerrequisitos
- [Foundry](https://getfoundry.sh/)
- [Node.js](https://nodejs.org/en) (para el backend/oráculo)

### Configuración
1.  **Clonar el repositorio y instalar dependencias:**
    ```bash
    git clone <tu-repo> ala-pool
    cd ala-pool
    forge install
    ```
2.  **Configurar `foundry.toml`:**
    Asegúrate de tener un endpoint RPC para `base_sepolia` y una clave de API de Etherscan (opcional, para verificación).

    ```toml
    [rpc_endpoints]
    base_sepolia = "https://sepolia.base.org"

    [etherscan]
    base_sepolia = { key = "TU_API_KEY" }
    ```
3.  **Variables de Entorno:**
    Necesitarás exportar la clave privada de la cuenta que desplegará el contrato.
    ```bash
    export PRIVATE_KEY="0x..."
    ```

### Despliegue del Hook
Ejecuta el script de despliegue. Esto compilará y desplegará tu `ALADynamicFeeHook` en Base Sepolia.
```bash
/home/spark/.foundry/bin/forge script script/DeployALAHook.s.sol --rpc-url base_sepolia --broadcast --verify -vvvv
```
La salida te dará la dirección del hook desplegado.

### Backend y Pruebas

Consulta las siguientes secciones para aprender a ejecutar el backend y probar el hook.

---

## 🚀 Deploy On-Chain: Ethereum Sepolia

### ✅ Despliegue Exitoso

El protocolo ALA ha sido desplegado exitosamente en **Ethereum Sepolia** con todas las funcionalidades implementadas:

- ✅ **Dynamic Fees**: Ajuste dinámico de comisiones basado en condiciones de mercado
- ✅ **Rehypothecation**: Capitalización automática de fondos inactivos en bóvedas ERC4626
- ✅ **Umbral**: Sistema de umbrales para optimización de rebalances
- ✅ **Delta**: Gestión de spread y captura de valor
- ✅ **Benefits**: Distribución de beneficios entre estrategia y protocolo

### 📋 Transacciones de Deploy

Todas las transacciones del despliegue completo están documentadas en:

- **[transactions-eth-sepolia.txt](./transactions-eth-sepolia.txt)**: Registro completo de todas las transacciones on-chain, incluyendo:
  - Creación de contratos MockERC20 (WETH, USDC, ALA Governance Token)
  - Despliegue de bóvedas ERC4626 (Vault WETH, Vault USDC)
  - Despliegue del ALADynamicFeeHook
  - Inicialización del Pool en Uniswap V4
  - Configuración de rehypothecation
  - Ejecución de swaps con fees dinámicos

### 🔄 Flujo de Trabajo

El flujo completo de despliegue y operación está documentado en:

- **[flujo-explicado.txt](./flujo-explicado.txt)**: Explicación detallada del flujo de trabajo, incluyendo:
  - **Flujo de Despliegue**: Proceso de instanciación de componentes en la blockchain
  - **Flujo Operativo**: Funcionamiento del sistema en producción
  - **Rehypothecation**: Mecanismo de capitalización automática
  - **Estructura de Costos**: Desglose de fees (0.05% dinámico + 0.01% protocolo)
  - **Mecanismo de Distribución**: Revenue split entre estrategia y plataforma

### 📊 Simulación y Resultados

Los resultados de las simulaciones y pruebas están disponibles en:

- **[simulacion-eth.txt](./simulacion-eth.txt)**: Resultados de simulaciones ejecutadas en Ethereum Sepolia

### 🔗 Contratos Desplegados

Los contratos principales desplegados en Ethereum Sepolia incluyen:

- **ALADynamicFeeHook**: Hook principal con lógica de fees dinámicos
- **PoolExecutor**: Contrato utilitario para ejecución de operaciones
- **MockERC4626 Vaults**: Bóvedas para rehypothecation de WETH y USDC

### 📝 Verificación On-Chain

Todas las transacciones pueden ser verificadas en:
- **Etherscan Sepolia**: [https://sepolia.etherscan.io](https://sepolia.etherscan.io)
- **Block Explorer**: Busca los hashes de transacción en el archivo `transactions-eth-sepolia.txt`



---



## 4. Seguridad: Separación de Claves (On-Chain vs. Off-Chain)



Nuestro sistema utiliza dos "roles" de claves privadas, que por seguridad deben ser distintas en un entorno de producción.



1.  **`PRIVATE_KEY` (Clave On-Chain):**

    *   **Función:** Es la clave de la cuenta que envía transacciones y paga el gas. En nuestro script de prueba, es la cuenta que crea el pool, añade liquidez y ejecuta el swap.

    *   **Representa:** Al "usuario" o "administrador" del sistema.



2.  **`TRUSTED_SIGNER_PRIVATE_KEY` (Clave Off-Chain):**

    *   **Función:** Su único propósito es firmar datos fuera de la cadena. Nuestro backend la usa para certificar criptográficamente que la nueva comisión dinámica es válida. **No envía transacciones.**

    *   **Representa:** Al "oráculo" o "servidor seguro".



**Buena Práctica (Producción):** Estas dos claves deben ser diferentes. Si un atacante roba la clave on-chain, solo puede acceder a los fondos de esa cuenta. Si roba la clave del oráculo, puede manipular la lógica de comisiones de todo el pool. Separarlas sigue el **Principio de Mínimo Privilegio**.



**A Fines Prácticos (Hackathon):** Para simplificar las pruebas, **estamos usando la misma clave privada para ambos roles**. La dirección pública de esta clave es la que se configura como `TRUSTED_SIGNER` en el contrato.



---



## 5. Probar el Hook

Hemos creado un script (`script/TestHook.s.sol`) que simula el ciclo de vida completo para probar la funcionalidad de tu hook de tarifa dinámica.

### ¿Qué hace `TestHook.s.sol`?
Este script automatiza el siguiente flujo de usuario, verificando la integración entre tu hook y Uniswap V4:
1.  **Crea un Pool de Liquidez:** Inicializa un nuevo pool WETH/USDC en el `PoolManager` de Uniswap V4, configurado para usar tu `ALADynamicFeeHook`.
2.  **Añade Liquidez:** Deposita una cantidad inicial de WETH y USDC en el pool.
3.  **Simula el Backend:** Genera una tarifa dinámica y la firma criptográficamente, como lo haría tu backend/oráculo.
4.  **Realiza un Swap:** Ejecuta una operación de intercambio (swap) en el pool recién creado, utilizando la tarifa dinámica firmada.

Si el script se ejecuta sin errores hasta el final, significa que tu `ALADynamicFeeHook` ha sido desplegado correctamente, puede ser inicializado con un pool y valida exitosamente las firmas del "backend" para aplicar la tarifa dinámica en un swap.

### ¿Cómo Funciona `TestHook.s.sol` (Paso a Paso)?

1.  **Configuración Inicial:** El script define las direcciones de los contratos importantes (PoolManager, tu Hook, Trusted Signer) y los tokens WETH/USDC para Base Sepolia.
2.  **Preparación del Desplegador:** Obtiene las claves privadas del entorno para el desplegador/swapper y para el `TRUSTED_SIGNER` (recuerda que para la hackathon usamos la misma para ambos).
3.  **Creación e Inicialización del Pool:**
    *   Calcula una `PoolKey` que incluye las direcciones de WETH y USDC, una tarifa base (0.3%) y, crucialmente, la dirección de tu `ALADynamicFeeHook`.
    *   Llama a `POOL_MANAGER.initialize()` para crear el pool.
4.  **Aprovisionamiento de Fondos y Liquidez:**
    *   Usa el cheatcode `deal` de Foundry para otorgar tokens WETH y USDC al contrato del script para simular fondos.
    *   Aprueba al `PoolManager` para gastar estos tokens.
    *   Llama a `POOL_MANAGER.modifyLiquidity()` para añadir liquidez inicial al pool.
5.  **Simulación del Oráculo/Backend:**
    *   Define una `dynamicFee` (ej. 1%) y un `deadline` (un minuto en el futuro).
    *   Construye un `messageHash` que incluye el `poolId`, la `dynamicFee`, el `deadline` y el `block.chainid` (¡esto debe coincidir exactamente con la lógica del hook!).
    *   Usa el cheatcode `vm.sign()` con la `TRUSTED_SIGNER_PRIVATE_KEY` para firmar el `messageHash`.
    *   Codifica la `dynamicFee`, el `deadline` y la `signature` en la estructura `FeeData` y luego en `hookData`.
6.  **Ejecución del Swap:**
    *   Llama a `POOL_MANAGER.swap()`, pasando el `poolKey`, los parámetros del swap (ej. vender 0.1 WETH) y el `hookData` generado por la simulación del backend.
    *   Tu `ALADynamicFeeHook` interceptará esta llamada en su `beforeSwap`, validará la firma y aplicará la tarifa dinámica.

### Compilar y Simular el Script para Testnet

1.  **Edita el Script de Prueba (`script/TestHook.s.sol`):**
    *   Reemplaza `0xACA_TU_HOOK_ADDRESS` con la dirección real de tu `ALADynamicFeeHook` desplegado.

2.  **Configura las Claves Privadas:**
    Asegúrate de que la dirección pública de la clave usada sea la misma que configuraste como `TRUSTED_SIGNER` (`0x8481...`).
    ```bash
    export PRIVATE_KEY="0xTU_UNICA_CLAVE_PRIVADA"
    export TRUSTED_SIGNER_PRIVATE_KEY="0xTU_UNICA_CLAVE_PRIVADA"
    ```

3.  **Ejecuta la Simulación:**
    Este comando compilará y ejecutará el script, pero **sin enviarlo a la blockchain**. Es útil para depurar y ver los logs.

    ```bash
    /home/spark/.foundry/bin/forge script script/TestHook.s.sol --rpc-url base_sepolia -vvvv
    ```

    *   `--rpc-url base_sepolia`: Indica a Forge que use el endpoint `base_sepolia` definido en `foundry.toml` para las simulaciones de lectura de estado.
    *   `-vvvv`: Aumenta la verbosidad para ver todos los logs de la consola.

### Uso rápido parametrizable (`script/TestHook.s.sol`)

- **Variables requeridas**  
  `PRIVATE_KEY` (deployer), `TRUSTED_SIGNER_PRIVATE_KEY` (debe coincidir con el `TRUSTED_SIGNER` del hook), `ALA_HOOK_ADDRESS` (hook minado con flags válidos).

- **Opcionales (con defaults Base Sepolia)**  
  `WETH_ADDRESS` (default `0x4200000000000000000000000000000000000006`)  
  `USDC_ADDRESS` (default `0x036CbD53842c5426634e7929541eC2318f3dCF7e`)  
  `WETH_AMOUNT` default `10e18`  
  `USDC_AMOUNT` default `20000e6`  
  `LIQUIDITY_DELTA` default `1e18`  
  `SWAP_AMOUNT_IN` default `0.1e18` (se usa negativo en `amountSpecified`)  
  `SIMULATION` (bool): si `true`, usa `MockERC20` para evitar errores de `deal()` con Proxies en simulación; si no, transfiere tokens reales.

- **Simulación (Recomendada para testing)**  
  Para evitar problemas con tokens Proxy (como USDC en testnet) al usar `deal()`, activa el modo simulación. Esto desplegará tokens Mock automáticamente.
  ```bash
  export PRIVATE_KEY=0x...
  export TRUSTED_SIGNER_PRIVATE_KEY=0x...
  export ALA_HOOK_ADDRESS=0x<tu_hook>
  export SIMULATION=true
  forge script script/TestHook.s.sol --tc TestHook --rpc-url base_sepolia -vvvv
  ```

- **On-chain con montos bajos (ejemplo)**  
  Si quieres ejecutar contra el pool real en Base Sepolia (necesitas tener tokens reales).
  ```bash
  export PRIVATE_KEY=0x...
  export TRUSTED_SIGNER_PRIVATE_KEY=0x...
  export ALA_HOOK_ADDRESS=0x<tu_hook>
  export WETH_AMOUNT=10000000000000000       # 0.01 WETH
  export USDC_AMOUNT=20000000                # 20 USDC (6 dec)
  export LIQUIDITY_DELTA=10000000000000000   # 0.01
  export SWAP_AMOUNT_IN=1000000000000000     # 0.001 WETH
  forge script script/TestHook.s.sol --tc TestHook --rpc-url base_sepolia --broadcast -vvvv
  ```

- **Qué hace internamente**  
  1) **Setup Tokens**: Si `SIMULATION=true`, despliega `MockERC20` para WETH y USDC. Si no, usa las direcciones de la red.
  2) **Initialize Pool**: Crea el pool con fee dinámico y tu hook (`ALA_HOOK_ADDRESS`).  
  3) **Backend Sim**: Construye `hookData` firmado (fee, deadline, signature).  
  4) **Executor**: Despliega `PoolExecutor`. Si es simulación, le inyecta fondos con `mint()`. Si es real, le transfiere fondos desde tu wallet.
  5) **Execution**: Llama `unlock` -> `modifyLiquidity` (añade liquidez) -> `swap` (hace el swap usando el `hookData`).
  6) **Settlement**: Liquida los deltas resultantes.


### Salida de Ejemplo (Éxito)

Una ejecución exitosa producirá logs similares a esto. Las direcciones y hashes variarán, pero la secuencia de eventos y el mensaje final de éxito son lo importante.

```
[⠊] Compiling...
[⠒] Compiling 1 files with Solc 0.8.26
[⠑] Solc 0.8.26 finished in 500.00ms
Compiler run successful with warnings:
Warning (2018): Function state mutability can be restricted to view
  --> src/ALADynamicFeeHook.sol:54:5:
   |
54 |     function beforeSwap(
   |     ^ (Relevant source part starts here and spans across multiple lines).

Traces:
  [some_long_number] → new TestHook@0x...
    └─ ← [Return] <script_bytecode>

  [some_other_long_number] TestHook::run()
    ├─ [0] VM::envUint("PRIVATE_KEY") [staticcall]
    │   └─ ← [Return] <env_var_value>
    ├─ [0] VM::envUint("TRUSTED_SIGNER_PRIVATE_KEY") [staticcall]
    │   └─ ← [Return] <env_var_value>
    ├─ [0] VM::addr(<pk_value>) [staticcall]
    │   └─ ← [Return] 0xYOUR_DEPLOYER_ADDRESS
    ├─ [0] VM::startBroadcast(<pk_value>)
    │   └─ ← [Return]
    ├─ [0] POOL_MANAGER.initialize(<pool_key>, <sqrt_price>, 0x)
    │   └─ ← [Return]
    ├─ Logs:
    │     Pool Creado. ID: 0x...
    ├─ [0] VM::deal(0xWETH_ADDRESS, 0xYOUR_DEPLOYER_ADDRESS, 10000000000000000000) [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::deal(0xUSDC_ADDRESS, 0xYOUR_DEPLOYER_ADDRESS, 20000000000000) [staticcall]
    │   └─ ← [Return]
    ├─ [0] WETH.approve(0xPOOL_MANAGER_ADDRESS, <max_uint256>)
    │   └─ ← [Return]
    ├─ [0] USDC.approve(0xPOOL_MANAGER_ADDRESS, <max_uint256>)
    │   └─ ← [Return]
    ├─ [0] POOL_MANAGER.modifyLiquidity(<params>, 0x)
    │   └─ ← [Return]
    ├─ Logs:
    │     Liquidez Añadida.
    ├─ [0] VM::stopBroadcast()
    │   └─ ← [Return]
    ├─ Logs:
    │     Fee Dinámico Firmado: 10000
    │     hookData generado: 0x... (una larga cadena de bytes)
    ├─ [0] VM::startBroadcast(<pk_value>)
    │   └─ ← [Return]
    ├─ [0] POOL_MANAGER.swap(<pool_key>, <swap_params>, 0x...hookData...)
    │   └─ ← [Return]
    ├─ Logs:
    │     Swap ejecutado exitosamente con tarifa dinámica!
    └─ [0] VM::stopBroadcast()
        └─ ← [Return]

Ran 1 test for script/TestHook.s.sol:TestHook
[PASS] run() (gas: 1234567)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.23s (edited)

-------------------------------------------------------------------------------------------------
Test result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.23s
