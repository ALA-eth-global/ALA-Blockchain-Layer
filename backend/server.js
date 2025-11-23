require('dotenv').config();
const express = require('express');
const { ethers } = require('ethers');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 3000;
const PRIVATE_KEY = process.env.TRUSTED_SIGNER_PRIVATE_KEY;

if (!PRIVATE_KEY) {
    console.error("❌ ERROR: TRUSTED_SIGNER_PRIVATE_KEY no está definida en .env");
    process.exit(1);
}

const wallet = new ethers.Wallet(PRIVATE_KEY);

console.log("✅ Oracle Backend Iniciado");
console.log("🔑 Signer Address:", wallet.address);

// Endpoint principal para obtener el fee firmado
app.get('/api/quote-fee', async (req, res) => {
    try {
        // 1. Parámetros recibidos del frontend (o defaults)
        const poolId = req.query.poolId; // Hash del PoolKey
        const chainId = req.query.chainId || 84532; // Base Sepolia default

        if (!poolId) {
            return res.status(400).json({ error: "poolId is required" });
        }

        // 2. Lógica de AI (Simulada para Hackathon)
        // Aquí iría la llamada a tu modelo de Python/TensorFlow.
        // Simulamos volatilidad alta:
        const isHighVolatility = Math.random() > 0.5; 
        const feePips = isHighVolatility ? 10000 : 500; // 1% vs 0.05%
        
        // 3. Construir el mensaje a firmar (EIP-191)
        // Debe coincidir EXACTAMENTE con el abi.encodePacked de Solidity
        const deadline = Math.floor(Date.now() / 1000) + 300; // Expira en 5 minutos

        // Solidity: keccak256(abi.encodePacked(poolId, fee, deadline, chainId))
        // Ethers: solidityPackedKeccak256
        const messageHash = ethers.solidityPackedKeccak256(
            ["bytes32", "uint24", "uint256", "uint256"],
            [poolId, feePips, deadline, chainId]
        );

        // 4. Firmar
        // messageHash ya es un bytes32. wallet.signMessage agrega automáticamente el prefijo "\x19Ethereum Signed Message:\n32"
        // Pero ojo: en Solidity hacemos keccak256(abi.encodePacked("\x19...", messageHash)).
        // wallet.signMessage hace hash del mensaje. Si le pasamos un hash (bytes), ethers lo trata como data binaria.
        const signature = await wallet.signMessage(ethers.getBytes(messageHash));

        // 5. Empaquetar hookData para el Frontend
        // struct FeeData { uint24 newFee; uint256 deadline; bytes signature; }
        const abiCoder = new ethers.AbiCoder();
        const hookData = abiCoder.encode(
            ["tuple(uint24 newFee, uint256 deadline, bytes signature)"],
            [[feePips, deadline, signature]]
        );

        console.log(`[Oracle] Firmado: Fee=${feePips/10000}% | Volatilidad=${isHighVolatility ? 'ALTA' : 'BAJA'}`);

        res.json({
            success: true,
            fee: feePips,
            feeLabel: `${feePips / 10000}%`,
            volatility: isHighVolatility ? "HIGH" : "LOW",
            deadline: deadline,
            signature: signature,
            hookData: hookData // Esto es lo que se envía al contrato
        });

    } catch (error) {
        console.error("Error firmando:", error);
        res.status(500).json({ error: "Internal Server Error" });
    }
});

app.listen(PORT, () => {
    console.log(`🚀 Servidor corriendo en http://localhost:${PORT}`);
});

