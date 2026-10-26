# zkPassport digest bind fixture

Generated on 2026-10-23, replacing the 0.21.0 proof of 2026-10-05 when the table moved to zkPassport 0.21.1. This page is for whoever reviews or regenerates the proof behind the positive zkPassport verdict in `test/deploy-identity/fork/DeployIdentityZkPassportVerdictFork.t.sol`. The three data files hold one zkPassport 0.21.1 bind proof whose custom data is `0xb6566bf299a764e0c0a1f4ca4805b7b977ea3a018675b1596e7363854202ec53`, the zkPassport method's rendering of that digest. The digest is `keccak256("zkpassport deployment digest")`, a fixed test value. On a Sepolia fork at block 11,977,408 the identity script deploys the method with Sepolia's table, and the method answers this proof and digest with the magic value, with only the root registry's check of the certificate root mocked.

## Files

- `valid_proof.hex` (9,888 bytes), `valid_public_inputs.json` (ten inputs), `valid_committed_inputs.hex` (695 bytes): written by upstream's `src/ts/scripts/generate-fixtures.ts`, unchanged.
- `ZkPassportDigestBindFixture.sol`: the same bytes as Solidity constants, which the tests inherit. Tests may read files only under `test/fixtures/kats` and `out`, so they cannot read the data files directly.
- `generate.py`: writes `ZkPassportDigestBindFixture.sol` from the three data files, and refuses committed inputs that do not carry the digest's rendering.
- `NOTICE` and `LICENSE`: the Apache-2.0 attribution and upstream's licence text, copied unchanged from the commit below.

## How it was made

The generator ran in a scratch clone of `zkpassport/circuits` at `9682885268d631f1331513be88ba5646961f77f0`, the 0.21.1 release commit, outside this repository. The toolchain was the one upstream's CI names at that commit: nargo `1.0.0-beta.22` and bb `5.0.0`, from their GitHub release binaries, and Node 23.11 with `npm ci` (upstream's CI names Node 24.3; the generator does not depend on the difference).

1. `./node_modules/.bin/tsx src/ts/scripts/circuit-builder.ts generate && nargo fmt`, which left `git status` clean.
2. `nargo compile --force --package <name>` for the six circuits the five-subproof fixture uses: `sig_check_dsc_tbs_700_rsa_pkcs_4096_sha512`, `sig_check_id_data_tbs_700_rsa_pkcs_2048_sha256`, `data_check_integrity_sa_sha256_dg_sha256`, `disclose_bytes_evm`, `bind_evm` and `outer_count_5`.
3. `TZ=UTC npm run generate-fixtures`, with `generate-fixtures.ts` changed as below. Proving took about a minute.

The change to `generate-fixtures.ts` replaces the bind query's custom data and stops after the five-subproof fixture, skipping the thirteen-subproof and salted fixtures this repository does not use:

```diff
-        custom_data: "email:test@test.com,customer_id:1234567890",
+        custom_data: "0xb6566bf299a764e0c0a1f4ca4805b7b977ea3a018675b1596e7363854202ec53",
@@ generate()
+    {
+      const outputPath = path.join(__dirname, "..", "..", "solidity", "test", "fixtures")
+      fs.writeFileSync(path.join(outputPath, "valid_proof.hex"), outerProof5.proof.map((x) => x.replace("0x", "")).join(""))
+      fs.writeFileSync(path.join(outputPath, "valid_public_inputs.json"), JSON.stringify({ inputs: outerProof5.publicInputs }, null, 2))
+      fs.writeFileSync(path.join(outputPath, "valid_committed_inputs.hex"), discloseCommittedInputs + bindCommittedInputs)
+      console.log("Five-subproof fixture written; the other fixtures are skipped")
+      return
+    }
```

## What the proof is

The proof is an outer proof over five subproofs, the last two a disclosure and a bind, for upstream's fake test passport, whose certificates the generator signs locally. Its circuit root, public input 1, is `0x070d61a69d948675774a2f56fdba0bd4ffede26308b468348762d1dc4c34b69d`, the root of the 0.21.1 circuit manifest and the latest root of the live circuit registry at the pinned block (since 2026-10-22 on both chains), so its check runs unmocked. Its certificate root, public input 0, is a local test root no live registry holds, which is why the tests mock that one check. Its date, public input 2, is `0x6adb74d9`, 2026-10-23 14:53:13 UTC, and the Sepolia block the tests fork comes after it. Its scoped nullifier, second from the end of the public inputs, is `0x171de101deed3f056917faecfe6cc04db2ef02689a8a483962a688948ce44461`, and its nullifier type, third from the end, is 0. Its domain is `zkpassport.id` and its scope `bigproof`. The tests route it with the verification key hash `0x14765cfe42f6c72ea39d5c9be96c3e9a39b2e982ec5f0133749f88e0f00bcc27`, the one the 0.21.1 sub-verifier registers for a five-subproof outer proof. The 0.21.1 sub-verifier no longer registers the 0.21.0 hash, so a 0.21.0 proof cannot pass through the 0.21.1 route.

Proving is randomized, so a second run gives a different proof with a new date. The files are frozen: do not replace them with a new run, since the pinned fork block must come after the proof's date.

## Regenerating the constants

From the repository root:

```sh
python3 test/fixtures/zkpassport-digest/generate.py
forge fmt --check test/fixtures/zkpassport-digest/ZkPassportDigestBindFixture.sol
git diff --exit-code test/fixtures/zkpassport-digest/ZkPassportDigestBindFixture.sol
```

The script needs only the Python 3 standard library. On unchanged data files the last command finds no difference.
