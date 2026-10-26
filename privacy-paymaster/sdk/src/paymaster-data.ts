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
