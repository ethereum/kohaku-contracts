# kohaku-contracts

Foundry monorepo. Each top-level directory with its own `foundry.toml` is an independent Forge project. The Nix flake at the root is shared. GitHub workflows run each package from `.github/workflows/`.

## Packages

- [`privacy-paymaster`](privacy-paymaster/) — EIP-4337 paymasters for privacy protocols. Ported from [Robert-MacWha/privacy-paymaster](https://github.com/Robert-MacWha/privacy-paymaster) at `9695708`.

Solidity in that package stays `SPDX-License-Identifier: UNLICENSED`. The root MIT license does not relicense it.

## Development

The easiest way to get a stable dev environment is nix. [Install Nix here](https://nixos.org/download/), then run:

```shell
nix develop --extra-experimental-features "nix-command flakes" --command $SHELL
```

Work inside that shell. It pins the toolchain CI uses.

```shell
cd privacy-paymaster
forge build
forge test -vvv
```

`forge test` forks Sepolia and needs `SEPOLIA_RPC_URL`. That value is in `privacy-paymaster/secrets/secrets.yaml`, encrypted for the keys listed in `privacy-paymaster/.sops.yaml`.
