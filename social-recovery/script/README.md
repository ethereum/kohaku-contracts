# Deploying the demo path

> Read each command before you run it, and check the result of each step against what this page says. Run every command from the `social-recovery/` folder.

This page is for whoever runs the deployment, and it assumes no earlier forge deployment. It explains what `script/Deploy.s.sol` deploys and how to rehearse it. It then explains how to run it on a real chain and what to do when a check fails.

## What the script deploys

The script deploys the four contracts of the demo path, in one broadcast and at fresh addresses.

- The policy manager, which holds every account's recovery setup.
- The wallet method, which accepts approvals signed by a guardian's wallet.
- The passkey method, which accepts approvals signed by a guardian's passkey.
- The recovery action, which hands an Ambire account to its new owner. Its constructor takes the manager this run deployed and the Ambire account implementation at `0x0F2AA7bcda3d9D210dF69a394b6965CB2566c828`.

The identity methods (zkPassport and Aadhaar) are not part of this script. They deploy from a second script, `script/DeployIdentity.s.sol`, described under [Identity methods](#identity-methods) at the end of this page. No contract here has a proxy or an upgrade admin, so a change always means a new deployment.

The script runs on two chains only, Ethereum mainnet (chain id 1) and Sepolia (chain id 11155111). On any other chain id it stops with `Deploy_UnsupportedChain`, in the deployment and in confirm alike, before any other check.

## The checks it runs

The script checks the chain before it deploys and checks the contracts after it deploys them. Any failing check reverts the whole script. Forge simulates the whole script before it sends any transaction, so a failing check means nothing is sent.

Before anything else, the script looks up the chain's pins, which stops an unsupported chain with `Deploy_UnsupportedChain`. It then applies the label rule to `DEPLOYMENT_LABEL` when that variable is set, which stops an invalid label with `Deploy_InvalidLabel`, as described under [Rehearsal on a Tenderly Virtual TestNet](#rehearsal-on-a-tenderly-virtual-testnet). Both run in a dry run too.

Then, before deploying, the script runs two checks.

1. It sends a known valid passkey signature to the chain's P256VERIFY precompile at `0x100` and requires the answer 1. Without it the passkey method would refuse every passkey. The error is `Deploy_P256VerifyNotLive`.
2. It requires the Ambire implementation address to have code, and that code to have the pinned code hash. The errors are `Deploy_ImplementationHasNoCode` and `Deploy_ImplementationCodehashMismatch`.

After deploying, the script reads the new contracts back and runs six more checks.

1. The recovery action names the manager this run deployed and the pinned implementation. The errors are `Deploy_ActionManagerMismatch` and `Deploy_ActionImplementationMismatch`.
2. The action's slot in the account's privilege table differs from the slot Ambire's own helper would give the same binding. The error is `Deploy_KitSlotCollides`.

   The script reads the action's manager, implementation and slot with guarded calls. When a read reverts or gives an answer that is not one well-formed address, for example because the address holds another contract, the error is `Deploy_ReadFailed` with the record key `recoveryAction` and the address.
3. The wallet and passkey methods declare no key admin, no trusted key and no pause holder. The error is `Deploy_MethodDeclaresRoles`.
4. Each contract answers ERC-165 for its interfaces. The error is `Deploy_InterfaceNotSupported`.
5. The wallet method answers `name()` with `method-ecdsa` and the passkey method with `method-passkey`. The two methods pass the two checks above alike, so this is the check that catches a record that swaps them. The error is `Deploy_MethodMismatch`, with the address, the expected name and the name it answered. When the `name()` call reverts or its answer is not a well-formed string, the error is `Deploy_ReadFailed`, with the record key (`ecdsaMethod` or `passkeyMethod`) and the address.
6. Each of the four addresses runs exactly the kit's code. The checks above read answers a contract chooses, so a contract written to give the same answers would pass them, and only the code hash ties an address to the reviewed code. The manager and the two methods hold no immutable, so their code hash must equal the hash of the compiled runtime code. The action holds immutables, two of them derived from its own address, so the script runs the action's constructor at the action's address, with the recorded manager and the pinned implementation, and compares the hash of the code it returns. It does this on its local copy of the chain, after the broadcast has stopped, and puts the address's code back, so nothing is sent. The error is `Deploy_CodeMismatch`, with the record key (`policyManager`, `ecdsaMethod`, `passkeyMethod` or `recoveryAction`), the address, the expected code hash and the one found. This check runs last, so a more specific error above names a mistake first.

## Step 0: run the fork tests before every deployment

The fork tests run the scripts and the methods against real copies of mainnet and Sepolia. They need RPC endpoints and skip without them, so no automated run covers them. Run them before every deployment, of either script, with endpoints that serve historical state.

```sh
MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co \
SEPOLIA_RPC_URL=https://sepolia.gateway.tenderly.co \
forge test --match-path 'test/**/*Fork.t.sol'
```

The tests fork each chain at a fixed past block, so the results do not change as the chains move on. Many free endpoints prune old state and answer only for recent blocks, and the tests then fail with a missing state error rather than a real failure. Without the two variables every fork test is skipped, which proves nothing. Check that the summary line shows passed tests and no skipped ones.

## Keys

The deployer key lives in an encrypted keystore, never on the command line or in a file. Import it once, giving it a name of your choice, here `kit-deployer`.

```sh
cast wallet import kit-deployer --interactive
```

Cast asks for the private key and for a password, and stores the key encrypted under `~/.foundry/keystores/`. Every later command passes `--account kit-deployer`, and forge asks for the password when it needs to sign. To see the deployer's address, run `cast wallet address --account kit-deployer`.

The deployer only pays for gas. It gets no role in the kit, because no contract stores the address that deployed it. The Sepolia dry run estimated about 6.9 million gas for the whole deployment, about 0.013 ETH at 2 gwei. That run predates the gas change described under [Gas limits on Sepolia](#gas-limits-on-sepolia), and on Sepolia the four contracts now need about 37.7 million gas. Fund the deployer with a margin above the estimate forge prints for your run, and on Sepolia above the raised limits that section describes.

## Gas limits on Sepolia

This section explains why every broadcast on Sepolia carries one more flag. Its figures were measured on 2026-10-08.

Glamsterdam activated on Sepolia on 2026-10-06 (EIP-8037), and it raised the gas a contract creation costs. Storing contract code now costs 1,530 gas per byte instead of 200, and a CREATE starts at 183,600 gas. Forge simulates the script under the repository's `evm_version = "osaka"`, so it sets each gas limit from the old prices. The limits come out about seven times too low, and the creation fails on the chain with "contract creation code storage out of gas". The policy manager got a limit of 3.67 million and needed about 20 million.

Every broadcast on Sepolia therefore adds `--gas-estimate-multiplier 1000`. The value is a percentage, so forge sets each gas limit at ten times its estimate instead of the default 130 percent. The flag raises only the limit forge sets. A transaction pays for the gas it uses, so the unused gas is not spent. The node still requires the deployer's balance to cover each limit at the offered fee before it accepts the transaction, so fund the deployer for the raised limits. The flag acts only when forge simulates. A `--resume` sends the transactions forge saved, with the limits it saved, so adding the flag to a resume raises nothing.

eth_estimateGas on Sepolia on 2026-10-08 gave these costs for each creation.

- The policy manager, 20.15 million.
- The recovery action, 10.88 million.
- The wallet method, 2.41 million.
- The passkey method, 4.21 million.
- The zkPassport method, 11.4 million.

The lasting fix is to simulate under the new rules. That would change `foundry.toml` and with it the kit's code hashes, so it is left for a coordinated redeployment. Mainnet had not activated the change on 2026-10-08. Before a mainnet deployment, check whether mainnet has activated it since. If it has, add the same flag to every mainnet broadcast. A Tenderly Virtual TestNet forked from Sepolia may run the old rules or the new ones. If a rehearsal's creation fails with the same error, add the same flag to its broadcast.

## Dry run

A dry run simulates the whole script against a chain and sends nothing. Leave out `--broadcast` and the key.

```sh
forge script script/Deploy.s.sol --rpc-url <url>
```

It runs every check and prints the addresses the contracts would get, then the gas estimate. It writes no record under `script/deployments/`. Forge itself saves the simulated transactions under `broadcast/`, a folder the repository ignores.

Check that the dry run wrote no record. Run `ls script/deployments/` before and after the dry run and compare the two lists. No new `.pending.json` file may appear. If one appeared, stop. The dry run wrote a record it must not write, and no broadcast follows until the cause is found.

## Rehearsal on a Tenderly Virtual TestNet

A rehearsal runs the real two steps on a private copy of a chain, so the first broadcast you ever make is not on a real chain. Prepare the copy in the Tenderly dashboard first.

1. Create a Virtual TestNet forked from Sepolia (or from mainnet).
2. Keep the original chain id, 11155111 for Sepolia or 1 for mainnet. The script accepts only those two and refuses a custom chain id.
3. Keep the TestNet's public explorer off.
4. Fund the deployer's address from the TestNet's dashboard.
5. Copy the TestNet's RPC URL.

Then deploy, with a label that keeps the rehearsal's record apart from the real one.

```sh
DEPLOYMENT_LABEL=tenderly-sepolia forge script script/Deploy.s.sol \
  --rpc-url <tenderly-rpc> --account kit-deployer --broadcast --slow
```

`--slow` makes forge wait for each transaction to be confirmed before it sends the next. Without it, forge sends them all at once, and a node that runs them out of nonce order puts each contract at another's address. A Tenderly Virtual TestNet did that once, and confirm caught it. Every broadcast command on this page carries it.

The script writes a candidate record to `script/deployments/tenderly-sepolia.pending.json`. It is only a candidate because forge writes it during the simulation, before any transaction lands.

Check that the candidate appeared. Run `ls script/deployments/` and look for `tenderly-sepolia.pending.json`, or `<label>.pending.json` for another label. If it is missing, stop and do not run confirm.

Wait until forge reports every transaction as confirmed, then publish the record. Run confirm from the same commit and the same `foundry.toml` as the broadcast, with no change to the source in between. The compiled runtime code of each kit contract ends with a hash of its build's metadata. That metadata covers the contract's own source file, every file it imports, and the compiler settings, such as the optimizer and the EVM version that `foundry.toml` sets. A change to any of those files, a comment included, or to those settings alters the hash. A change to a file the contract does not import, such as a script, a test or this page, leaves it as it was. Confirm from a build with such a change therefore refuses a genuine deployment with `Deploy_CodeMismatch`.

```sh
DEPLOYMENT_LABEL=tenderly-sepolia forge script script/Deploy.s.sol \
  --sig 'confirm()' --rpc-url <tenderly-rpc>
```

Confirm reads the four addresses from the candidate and checks them on the chain, including that each runs exactly the kit's code. It then writes the published record to `script/deployments/tenderly-sepolia.json`, rebuilt from the values it checked rather than copied from the candidate, and removes the candidate. It needs no key, because it sends nothing.

Then compare each of the four addresses in the published record with the contract address forge printed for it during the broadcast. If any differs, do not use the record, and find out why. Confirm proves that each address runs the kit's code, not that your own broadcast created it.

A label is 1 to 64 characters of lowercase letters, digits and the hyphen, and at least one of them is not a digit. A label of digits alone could take another chain's record name, such as `1.json` written from Sepolia. Any other label stops the script with `Deploy_InvalidLabel`. The deployment applies the rule right after the chain check, before any other check and before anything is deployed, so a dry run stops on an invalid label too. The file `script/deployments/.gitignore` keeps every `tenderly-*` record and every `*.pending.json` candidate out of the repository. Git ignores the Tenderly records so a rehearsal's record never mixes with the real chains' committed records. The TestNet's RPC URL grants writes to the TestNet, so it is shared only through a private channel. To let the SDK and UX teams test against it, hand them both published records, `script/deployments/tenderly-sepolia.json` from this script and `script/deployments/tenderly-sepolia.identity.json` from the identity script, with the TestNet's RPC URL, directly and not through git. A real chain's published record is committed in its own pull request, and it is the record the SDK reads in production.

A rehearsal on a Tenderly fork always sets `DEPLOYMENT_LABEL`, for this script and for the identity script alike, because the fork keeps the real chain id. A rehearsal run without it writes the real chain's record: `<chainId>.json`, or `<chainId>.identity.json` for the identity script. The real record is committed, so after a rehearsal `git status` must show no change under `script/deployments/` other than the ignored `tenderly-*` files. A change there is a mistake. Undo it with `git checkout -- script/deployments/<file>`.

## A real chain

On mainnet or Sepolia the steps are the same two commands, without the label. First open a new terminal, or clear any label left from a rehearsal.

```sh
unset DEPLOYMENT_LABEL
```

A label still exported from a rehearsal makes the real broadcast write its candidate under the rehearsal's name.

Forge also reads a `.env` file in the project root on its own, and fills any variable the shell does not set from it. A label left there comes back after the `unset`. Check that no `.env` sets the label or the identity inputs.

```sh
grep -E 'DEPLOYMENT_LABEL|ZKPASSPORT_|AADHAAR_METHOD_SAFE' .env
```

No line may print, and a message that `.env` does not exist is fine. If a line prints, remove it from `.env` before you go on.

Start with a dry run against the same endpoint, and check with `ls script/deployments/` that it wrote no new `.pending.json` file, as [Dry run](#dry-run) says. If one appeared, stop. Then broadcast. On mainnet:

```sh
forge script script/Deploy.s.sol --rpc-url <url> --account kit-deployer --broadcast --slow
```

On Sepolia, with the flag [Gas limits on Sepolia](#gas-limits-on-sepolia) explains:

```sh
forge script script/Deploy.s.sol --rpc-url <url> --account kit-deployer --broadcast --slow \
  --gas-estimate-multiplier 1000
```

Check that the candidate appeared. Run `ls script/deployments/` and look for `<chainId>.pending.json`. If it is missing, stop and do not run confirm.

After every transaction is confirmed, publish the record. Run confirm from the broadcast's commit and `foundry.toml`, for the reason the rehearsal gives.

```sh
forge script script/Deploy.s.sol --sig 'confirm()' --rpc-url <url>
```

Then compare each of the four addresses in the published record with the contract address forge printed for it during the broadcast. If any differs, do not commit the record, and find out why. Confirm proves that each address runs the kit's code, not that your own broadcast created it.

Without a label the files take the chain id as their name. The candidate is `script/deployments/<chainId>.pending.json`, and the published record is `script/deployments/<chainId>.json`, for example `11155111.json` for Sepolia. The published record holds the chain id, the four addresses, the Ambire implementation and its code hash. Commit it in its own pull request, because it is the file the SDK reads.

If forge stops partway through the broadcast, for example on a timeout, rerun the broadcast command with `--resume` in place of `--broadcast`, and keep `--slow` on it. Forge then sends the transactions it saved that did not land, with the gas limits it saved, without simulating again. On Sepolia this works only when the stopped broadcast carried the gas flag, because a resume cannot raise a saved limit.

```sh
forge script script/Deploy.s.sol --rpc-url <url> --account kit-deployer --resume --slow
```

If a creation ran out of gas because the broadcast went out without the gas flag, do not resume. That transaction already used its nonce, so the remaining contracts would no longer land at the addresses forge predicted. Run a new broadcast with the flag from the start. It deploys a fresh set at new addresses, and its candidate replaces the old one. The contracts of the failed run are left unused. Check with `ls script/deployments/` that the candidate is there before you run confirm.

## What confirm checks and what to do when it fails

Confirm publishes a record only after the chain agrees with it. It runs these checks, in this order.

1. The chain has pins in the script's table. The error is `Deploy_UnsupportedChain`.
2. The label passes the label rule. The error is `Deploy_InvalidLabel`.
3. The chain's P256VERIFY precompile accepts the known valid signature, as in the first step. It runs before the candidate is read. The error is `Deploy_P256VerifyNotLive`.
4. The candidate names the chain confirm runs against. The error is `Deploy_RecordChainMismatch`.
5. Each of the four addresses has code on the chain. The error is `Deploy_NotDeployed`, and it usually means a transaction has not landed yet.
6. The code hash and then the implementation in the candidate equal the script's own table. The errors are `Deploy_ImplementationCodehashMismatch` and `Deploy_ActionImplementationMismatch`, the same as for the live checks, with the table's value as the expected one and the candidate's value as the actual one. Here they mean the candidate was edited or written by a build with another table, not that the chain changed.
7. The implementation check and the six deployment checks from the first step pass again, against the live contracts, with `Deploy_ReadFailed` for a read that fails. The last of them requires each of the four addresses to run exactly the kit's code (`Deploy_CodeMismatch`).

Only after every check passes does confirm write the published record. It rebuilds the record from the values the checks read: the chain id, the four addresses, and the implementation and code hash from the script's table. It never copies the candidate's text, so a key that no check read never reaches the published record.

When confirm fails, read the `Deploy_*` error name and its values in forge's output, and match them to the checks above. The candidate stays where it was and nothing is published, so you can rerun confirm once the cause is fixed. If the deployment itself is wrong, deploy again with the first command, which writes a new candidate over the old one.

A `Deploy_*` error that names an address holding another of the four contracts means the broadcast landed out of order, so each contract sits at another's predicted address. When the action's address holds the manager or a method, confirm fails with `Deploy_ReadFailed` and the record key `recoveryAction`, since those contracts do not answer the action's reads. A swap of the wallet and passkey methods fails with `Deploy_MethodMismatch`. Check what an address holds with `cast call <address> 'name()(string)' --rpc-url <url>`. Deploy again with `--slow`, without changing anything else.

A `Deploy_CodeMismatch` after a broadcast that went well usually means confirm ran from another build than the broadcast. The runtime code ends with a hash of the build's metadata, so a change since the broadcast to a kit contract's own source file or to any file it imports, even a comment, or to the compiler settings in `foundry.toml`, gives a different expected code hash. A change to a script, a test or this page does not. Check out the broadcast's commit and rerun confirm. The candidate is still there, so nothing needs deploying again.

## Contract verification

The script does not verify the contracts' source on Etherscan, and the commands above deliberately leave out `--verify`. Verification will be added in a later change.

## Redeploying

Every run deploys new contracts at new addresses, since nothing upgrades in place. A new manager starts empty. Every recovery setup and every approval gathered on the old manager stays with the old manager, so none of them carries over. After a redeployment the SDK must switch to the new published record, and every account must register its setup again on the new manager.

# Identity methods

> Read each command before you run it.

`script/DeployIdentity.s.sol` deploys the two identity methods. It has the same shape as the first script: a table per chain, every check before anything is sent, and the two-step record. The identity methods store no address of another kit contract, so this script runs on its own, before or after the demo path's script, and one method can be deployed again without touching the rest of the kit.

The operator runs only `run()` and `confirm()`, plus the read-only checks described on this page. The script's public `deploy(Pins, Inputs)` is a test entry point: it deploys with whatever pins its caller passes and never reads the chain's table, so an operator never calls it.

## What it deploys, and where

- On mainnet (chain id 1), the zkPassport method alone. No Anon Aadhaar verifier is published on mainnet, so no Aadhaar method ships there.
- On Sepolia (chain id 11155111), the zkPassport method and the Aadhaar method.

The zkPassport method takes eight trusted-key words in a fixed order. The first five come from the script's table: the accepted zkPassport version 0.21.1, the root verifier, the reviewed sub-verifier for that version, the verifier helper the root returns for it, and the root registry. The last three are inputs, described below. The Aadhaar method takes the Groth16 verifier at `0xCBd85cd69C4779aA9a7AB9B6D6A9f6FEd61504F0` and one trusted key, the hash of UIDAI's current public key, both from the table.

Each method gets its own Safe as its pause holder and its key admin. The two Safes may be one address. Any other chain id stops the script with `DeployIdentity_UnsupportedChain`, in the deployment and in confirm alike, before any other check.

## The five inputs

The script reads five environment variables on Sepolia and four on mainnet, where it never reads `AADHAAR_METHOD_SAFE`. Every one it reads is required, and an unset or empty one stops the script with `DeployIdentity_MissingInput` and the variable's name.

- `ZKPASSPORT_METHOD_SAFE` is the Safe that holds both roles of the zkPassport method, and `AADHAAR_METHOD_SAFE` the Safe that holds both roles of the Aadhaar method. The two may be the same address. At launch each is the Ethereum Foundation's Safe for that method on that chain. Until they exist, a rehearsal uses a Safe the team controls. On mainnet, where no Aadhaar method ships, the script does not read `AADHAAR_METHOD_SAFE` and records the zero address for that Safe, as it does for the method. A zero address in a Safe the script reads stops the script with `DeployIdentity_ZeroSafe` and the variable's name, `ZKPASSPORT_METHOD_SAFE` checked first. The script never puts the deployer's key in its place.
- `ZKPASSPORT_ROOT_ADMIN`, `ZKPASSPORT_ROOT_GUARDIAN` and `ZKPASSPORT_SUBVERIFIER_ADMIN` are the zkPassport roles the deployment team reviewed: the root admin, the root guardian and the sub-verifier's admin. The team supplies them after reviewing who holds each role. The script compares them with the live roles and stops on a difference. It never fills them from those live reads, since the comparison would then prove nothing. The root guardian may be the zero address when the root verifier has none, which was the case on both chains on 2026-10-05, but the variable must still be set.

While reviewing, you can read the live values with cast. Each answer is what the input will be compared with, not a value to copy without review.

```sh
ROOT=0x1D000001000EFD9a6371f4d90bB8920D5431c0D8
VERSION=0x0000001500010000000000000000000000000000000000000000000000000000
cast call $ROOT 'admin()(address)' --rpc-url <url>
cast call $ROOT 'guardian()(address)' --rpc-url <url>
cast call $(cast call $ROOT 'getSubVerifier(bytes32)(address)' $VERSION --rpc-url <url>) 'admin()(address)' --rpc-url <url>
```

## The checks it runs

Before anything else, the script looks up the chain's table (`DeployIdentity_UnsupportedChain`) and applies the label rule to `DEPLOYMENT_LABEL` when it is set (`DeployIdentity_InvalidLabel`). It then reads its inputs, five on Sepolia and four on mainnet, where it skips `AADHAAR_METHOD_SAFE` (`DeployIdentity_MissingInput`). All three run in a dry run too.

Then, before deploying, the script runs four checks.

1. The Safe of each method the chain deploys is nonzero (`DeployIdentity_ZeroSafe`, with the variable's name).
2. Every zkPassport address in the table has code, and on Sepolia so does the Aadhaar verifier (`DeployIdentity_NoCode`, with the address). On Sepolia the verifier's code must also have the pinned code hash, so a wrong contract at that address is caught (`DeployIdentity_AadhaarVerifierCodehashMismatch`).
3. Every zkPassport address word, from the root verifier to the sub-verifier admin, has nothing above its twenty address bytes (`DeployIdentity_WordNotClean`, with the word's position and the word). This runs before any live read, so a mismatch below never shows two equal addresses. Then the live zkPassport root verifier routes the accepted version to the table's sub-verifier with the table's verifier helper, and names the table's root registry (`DeployIdentity_ComponentMismatch`, with the component, the expected and the live address). Its live root admin and root guardian equal the two root role inputs, and the sub-verifier's live admin equals the third input (`DeployIdentity_RoleMismatch`, with the role, the expected and the live address). A read that fails reports the live value as the zero address.
4. On Sepolia, the Aadhaar key is not the Anon Aadhaar stack's published test key (`DeployIdentity_AadhaarTestKey`), nor one of UIDAI's two expired production keys, from the certificates of 2021 and 2024 (`DeployIdentity_AadhaarExpiredKey`).

After deploying, it reads each method back. Each must declare its own Safe as key admin and pause holder, no pending holder of either role and exactly the keys it was given (`DeployIdentity_MethodRolesMismatch`). Each must answer ERC-165 for its three interfaces (`DeployIdentity_InterfaceNotSupported`). The Aadhaar method must name the pinned verifier (`DeployIdentity_AadhaarVerifierMismatch`). Last, each method must run exactly the kit's code, since the checks before read answers a contract chooses (`DeployIdentity_CodeMismatch`, with the record key `zkPassportMethod` or `aadhaarMethod`, the address, the expected code hash and the one found). The zkPassport method holds no immutable, so its code hash must equal the hash of the compiled runtime code. The Aadhaar method holds its verifier as an immutable, so the script builds a local copy with the table's verifier, the Aadhaar method's Safe and the key, after the broadcast has stopped, and compares the two code hashes. The copy is never sent.

A component or role mismatch means zkPassport changed something since the last review. Do not change an input just to make the check pass. Review the change first, then update the table or the role inputs in their own change.

Before a deployment, check zkPassport's latest release. If it is newer than the table's 0.21.1, the method still deploys and its checks pass, since the root keeps routing older versions. But the app makes proofs of the newer version, which the method refuses until the zkPassport method's Safe moves the accepted version with `setTrustedKeys`, checked first with `checkZkPassportKeys` as [described below](#before-a-safe-settrustedkeys-transaction). Committed configs keep working, since they name no version.

## Commands

Before deploying on any chain, check that `ZKPASSPORT_METHOD_SAFE`, and on Sepolia `AADHAAR_METHOD_SAFE`, are the Safes the deployment team reviewed for that chain. They may be the same address, and then one check covers both. The script checks only that each Safe input is nonzero. A Safe address copied from another chain, or an ordinary account, would pass and become both roles of its method. First compare each address with the one the team reviewed for that method and chain. Then read the chain, once for each Safe.

```sh
cast code <safe> --rpc-url <url>
cast call <safe> 'getOwners()(address[])' --rpc-url <url>
cast call <safe> 'getThreshold()(uint256)' --rpc-url <url>
```

The first answer must be code, not `0x`. Code alone shows only that some contract sits at the address, so the owners and the threshold must also equal the ones the team reviewed. A deployment made with a wrong Safe is not repaired in place, since whoever holds the wrong address would have to hand both roles of that method over. Deploy again with the right Safe and use the new record.

Run the fork tests first, as [Step 0](#step-0-run-the-fork-tests-before-every-deployment) says. Then export the inputs in the shell, five on Sepolia and four on mainnet, and run a dry run. It sends nothing and writes no record.

```sh
forge script script/DeployIdentity.s.sol --rpc-url <url>
```

Check that the dry run wrote no record. Run `ls script/deployments/` before and after the dry run and compare the two lists. No new `.pending.json` file may appear. If one appeared, stop. The dry run wrote a record it must not write, and no broadcast follows until the cause is found.

A rehearsal on a Tenderly Virtual TestNet uses a label, as for the demo path, and the team's own Safe for both methods. Broadcast first.

```sh
DEPLOYMENT_LABEL=tenderly-sepolia forge script script/DeployIdentity.s.sol \
  --rpc-url <tenderly-rpc> --account kit-deployer --broadcast --slow
```

Check that the candidate appeared. Run `ls script/deployments/` and look for `tenderly-sepolia.identity.pending.json`, or `<label>.identity.pending.json` for another label. If it is missing, stop and do not run confirm. Otherwise, once every transaction is confirmed, publish the record. Run confirm from the broadcast's commit and `foundry.toml`, as for the demo path, or it refuses a genuine deployment with `DeployIdentity_CodeMismatch`.

```sh
DEPLOYMENT_LABEL=tenderly-sepolia forge script script/DeployIdentity.s.sol \
  --sig 'confirm()' --rpc-url <tenderly-rpc>
```

Then compare the method addresses in `script/deployments/tenderly-sepolia.identity.json` with the contract addresses forge printed during the broadcast, and its `zkPassportMethodSafe` and `aadhaarMethodSafe` with the values you set in `ZKPASSPORT_METHOD_SAFE` and `AADHAAR_METHOD_SAFE`. If anything differs, do not use the record, and find out why. Confirm proves that each address runs the kit's code, not that your own broadcast created it, and it publishes whatever Safes a coherent candidate names.

On a real chain, leave out the label. First open a new terminal, or clear any label left from a rehearsal.

```sh
unset DEPLOYMENT_LABEL
```

A label still exported from a rehearsal makes the real broadcast write its candidate under the rehearsal's name. Forge also fills any variable the shell does not set from a `.env` file in the project root, as the demo path explains. A rehearsal's label or Safe left there would override the `unset` and the missing-input check, so a forgotten `ZKPASSPORT_METHOD_SAFE` or `AADHAAR_METHOD_SAFE` would deploy with the rehearsal's Safe. Check that no `.env` sets them.

```sh
grep -E 'DEPLOYMENT_LABEL|ZKPASSPORT_|AADHAAR_METHOD_SAFE' .env
```

No line may print, and a message that `.env` does not exist is fine. If a line prints, remove it from `.env`, export the inputs in the shell again, and rerun the dry run. Then broadcast. On mainnet:

```sh
forge script script/DeployIdentity.s.sol --rpc-url <url> --account kit-deployer --broadcast --slow
```

On Sepolia, with the flag [Gas limits on Sepolia](#gas-limits-on-sepolia) explains:

```sh
forge script script/DeployIdentity.s.sol --rpc-url <url> --account kit-deployer --broadcast --slow \
  --gas-estimate-multiplier 1000
```

Check that the candidate appeared. Run `ls script/deployments/` and look for `<chainId>.identity.pending.json`. If it is missing, stop and do not run confirm. Otherwise, once every transaction is confirmed, publish the record, from the broadcast's commit and `foundry.toml`.

```sh
forge script script/DeployIdentity.s.sol --sig 'confirm()' --rpc-url <url>
```

Then compare the method addresses in `script/deployments/<chainId>.identity.json` with the contract addresses forge printed during the broadcast, and its `zkPassportMethodSafe` and `aadhaarMethodSafe` with the values you set in `ZKPASSPORT_METHOD_SAFE` and `AADHAAR_METHOD_SAFE`. On mainnet `aadhaarMethodSafe` must be the zero address. If anything differs, do not commit the record, and find out why. Confirm proves that each address runs the kit's code, not that your own broadcast created it, and it publishes whatever Safes a coherent candidate names.

If forge stops partway through the broadcast, rerun the broadcast command with `--resume` in place of `--broadcast` and keep `--slow` on it, as for the demo path. The resume sends the saved transactions with their saved gas limits, so on Sepolia it works only when the stopped broadcast carried the gas flag.

```sh
forge script script/DeployIdentity.s.sol --rpc-url <url> --account kit-deployer --resume --slow
```

If a creation ran out of gas because the broadcast went out without the gas flag, do not resume, for the reason the demo path gives. Run a new broadcast with the flag from the start. It deploys a fresh set at new addresses, and its candidate replaces the old one. The contracts of the failed run are left unused. Check with `ls script/deployments/` that the candidate is there before you run confirm.

The broadcast writes a candidate to `script/deployments/<label>.identity.pending.json`, where the label is the chain id when `DEPLOYMENT_LABEL` is not set. The `.identity` part keeps it apart from the demo path's record on the same chain and label, since a label cannot hold a dot. Once every transaction is confirmed, confirm publishes `script/deployments/<label>.identity.json` and removes the candidate. The record holds the chain id, the two method addresses (the Aadhaar one is the zero address on mainnet), the two Safes as `zkPassportMethodSafe` and `aadhaarMethodSafe` (the Aadhaar one is the zero address on mainnet), the eight zkPassport words, the Aadhaar verifier, its code hash and the Aadhaar key.

Confirm needs no key and none of the inputs, because it reads the two Safes and the role words from the candidate. It first looks up this chain's table, so another chain stops it with `DeployIdentity_UnsupportedChain` before anything else, and then applies the label rule. It then checks that the candidate names this chain (`DeployIdentity_RecordChainMismatch`), that its eight zkPassport words are eight (`DeployIdentity_WordCount`) and that the Safe of each method the chain deploys is nonzero (`DeployIdentity_ZeroSafe`, with the variable's name), as a deployment's is. On mainnet a recorded Aadhaar Safe other than zero fails with `DeployIdentity_RecordMismatch` and the key `aadhaarMethodSafe`. It then checks that each recorded method has code (`DeployIdentity_NotDeployed`). On mainnet, where no Aadhaar method ships, a recorded Aadhaar address other than zero also fails with `DeployIdentity_NotDeployed`. It then checks that the recorded table values equal the script's table, and runs every check above again against the live chain, the code check last. Only then does it write the published record, rebuilt from the values it checked, never copied from the candidate's text, so a key no check read never reaches it. A recorded outside address word with anything above its twenty address bytes fails with `DeployIdentity_WordNotClean`, and one that differs from the table with `DeployIdentity_ComponentMismatch`, and a recorded Aadhaar verifier with `DeployIdentity_AadhaarVerifierMismatch`. In these two errors the expected value is the table's and the actual value is the candidate's, so they mean the candidate was edited or written by a build with another table, not that the chain changed. Any other difference fails with `DeployIdentity_RecordMismatch` and the record key that holds it: `zkPassportKeys` for the accepted version or a role word with stray upper bytes, `aadhaarVerifierCodehash` or `aadhaarKey`. A label outside the label rule stops it with `DeployIdentity_InvalidLabel`, right after the chain check. The rule is the demo path's, so a label of digits alone is refused too, since it could take another chain's record name, such as `1.identity.json` written from Sepolia.

When `DeployIdentity_MethodRolesMismatch`, `DeployIdentity_InterfaceNotSupported` or `DeployIdentity_AadhaarVerifierMismatch` names an address that holds the other method, the broadcast landed out of order and the two methods swapped addresses. Check with `cast call <address> 'name()(string)' --rpc-url <url>`, which answers `method-zkpassport` or `method-aadhaar`. Deploy again with `--slow`, without changing any input. The candidate is not published, so nothing needs undoing.

A `DeployIdentity_CodeMismatch` from confirm after a broadcast that went well usually means confirm ran from another build than the broadcast, for the reason the demo path gives. Check out the broadcast's commit and rerun confirm. The candidate is still there, so nothing needs deploying again.

## Before a Safe setTrustedKeys transaction

The zkPassport method's Safe replaces its keys with `setTrustedKeys` after a reviewed zkPassport release or role change. Before anyone signs that transaction, run the same live check over the proposed eight words. It deploys nothing and sends nothing.

```sh
forge script script/DeployIdentity.s.sol --sig 'checkZkPassportKeys(bytes32[])' \
  '[<version>,<root>,<sub-verifier>,<verifier helper>,<registry>,<root admin>,<root guardian>,<sub-verifier admin>]' \
  --rpc-url <url>
```

Each word is 32 bytes in hex, and each address is left-padded with zeroes to 32 bytes. Before any read, the check requires exactly eight words (`DeployIdentity_WordCount`), then checks the seven address words in order, from the root verifier to the sub-verifier admin, for anything above their twenty address bytes (`DeployIdentity_WordNotClean`). "Script ran successfully" means the live root routes the proposed version to the proposed sub-verifier and verifier helper, names the proposed registry, and its roles and the sub-verifier's admin equal the proposed role words. A failure names the first word that disagrees, with the same errors as the deployment. The check does not compare the words with the script's table, since the point of the update is to move away from it. It also does not repeat what the method itself refuses, such as a zero word or a version word that is not canonical, since the method's own `setTrustedKeys` refuses those.

Before the Aadhaar method's Safe rotates its key with `setTrustedKeys`, run the Aadhaar key check over the proposed key. It deploys nothing, sends nothing and reads no chain, so it needs no endpoint.

```sh
forge script script/DeployIdentity.s.sol --sig 'checkAadhaarKey(bytes32)' <proposed key>
```

The key is 32 bytes in hex. "Script ran successfully" means the key is not the Anon Aadhaar stack's published test key (`DeployIdentity_AadhaarTestKey`), nor one of UIDAI's two expired production keys (`DeployIdentity_AadhaarExpiredKey`). It does not prove the key is UIDAI's current one, so also compare it with the hash of UIDAI's current public key before anyone signs.
