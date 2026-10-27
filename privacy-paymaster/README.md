# Privacy Paymasters

This repo contains implementations of 4337 paymasters for various privacy protocols (Tornado Cash, Railgun). These paymasters are designed to enable private unshields to new user accounts without needing a trusted per-protocol relayer. Users pay for their transactions using the private assets they hold or are unshielding.

For more information, see the docs in `docs/`. For information on specific protocol implementations, see the relevant subdirectories and docstrings in `contracts/`.

## Config Management
 - 'config/chains/chain.yaml' - Per-chain config files containing constants.

Tests and deploy scripts read `SEPOLIA_RPC_URL` from the environment. CI supplies it from the `SEPOLIA_RPC_URL` GitHub Actions secret.

## Deployment

Each protocol has its own paymaster, which must be staked and funded separately. The deploy scripts print and return the deployed addresses. Tornado and Privacy Pools paymasters are then allowlisted against the chain config's instances / pools with their setup scripts.

```bash
# Tornadocash
forge script DeployTornado --rpc-url $SEPOLIA_RPC_URL --verifier etherscan --verifier-api-key $ETHERSCAN_API_KEY --verify --broadcast
PAYMASTER_ADDRESS=0x... forge script SetupTornado --rpc-url $SEPOLIA_RPC_URL --broadcast

# Privacy Pools
forge script DeployPrivacyPools --rpc-url $SEPOLIA_RPC_URL --verifier etherscan --verifier-api-key $ETHERSCAN_API_KEY --verify --broadcast
PAYMASTER_ADDRESS=0x... forge script SetupPrivacyPools --rpc-url $SEPOLIA_RPC_URL --broadcast

# Railgun
forge script DeployRailgun --rpc-url $SEPOLIA_RPC_URL --verifier etherscan --verifier-api-key $ETHERSCAN_API_KEY --verify --broadcast

PAYMASTER_ADDRESS=0x... STAKE_AMOUNT=0 UNSTAKE_DELAY=0 DEPOSIT_AMOUNT=0 forge script StakePaymaster --rpc-url $SEPOLIA_RPC_URL --broadcast
```
