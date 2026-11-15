import { encodeAbiParameters, parseAbiParameters, type Address, type Hex } from "viem";

/// Encodes `TornadoPaymaster.PaymasterData`. The proof must be generated with
/// `relayer` set to the paymaster's address and `refund` set to 0.
export function encodeTornadoPaymasterData(
    instance: Address,
    proof: Hex,
    root: Hex,
    nullifierHash: Hex,
    recipient: Address,
    fee: bigint
) {
    return encodeAbiParameters(
        parseAbiParameters("(address instance, bytes proof, bytes32 root, bytes32 nullifierHash, address recipient, uint256 fee)"),
        [{
            instance,
            proof,
            root,
            nullifierHash,
            recipient,
            fee,
        }]
    );
}

/// Encodes `TacitPaymaster.PaymasterData`. The proof must be generated with
/// `relayer` set to the paymaster's address and `fee` set to the `fee` passed here, and must
/// insert nothing: both output leaves (`publicInputs[9]` and `publicInputs[10]`) are zero.
/// `extAmount` is negative: the withdrawal's recipient receives `-extAmount`.
export function encodeTacitPaymasterData(
    pool: Address,
    pA: readonly [bigint, bigint],
    pB: readonly [readonly [bigint, bigint], readonly [bigint, bigint]],
    pC: readonly [bigint, bigint],
    publicInputs: readonly bigint[],
    recipient: Address,
    extAmount: bigint,
    fee: bigint
) {
    if (publicInputs.length !== 11) throw new Error("publicInputs must have 11 entries");

    return encodeAbiParameters(
        parseAbiParameters(
            "(address pool, uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256[11] publicInputs, address recipient, int256 extAmount, uint256 fee)"
        ),
        [{
            pool,
            pA,
            pB,
            pC,
            publicInputs,
            recipient,
            extAmount,
            fee,
        }]
    );
}
