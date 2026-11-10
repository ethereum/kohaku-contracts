# Scenarios

Each scenario is one goal of a user of the kit, told step by step from outside the contracts: who acts, what they send, and what must hold afterwards. Where an invariant says what must never be false, a scenario says what happens in order, so the two catch different defects. Every scenario lists the tests under `test/integration/` that walk it.

The words the scenarios use:

- **The holder** owns the account.
- **The helpers** approve a recovery: guardians, the holder's own devices and identity proofs.
- **The manager** is the policy manager.
- **The action** is the recovery action.
- **A method** is the contract that judges one kind of proof.
- **Anyone** means any address with funds and no authority of its own.

Keys are named in words: the holder's key, the lost key, the new key. Section ids such as D-103 point to [`contracts.md`](contracts.md). Maya's rule, which most scenarios use, is spelled out in S-01.

## Index

- [S-01 Set up recovery](#s-01-set-up-recovery)
- [S-02 Recover lost key with approvers](#s-02-recover-lost-key-with-approvers)
- [S-03 Owner cancels unwanted recovery](#s-03-owner-cancels-unwanted-recovery)
- [S-04 Guardians cancel hostile recovery without key](#s-04-guardians-cancel-hostile-recovery-without-key)
- [S-05 Edit setup while recovery runs](#s-05-edit-setup-while-recovery-runs)
- [S-06 Turn recovery off and on](#s-06-turn-recovery-off-and-on)
- [S-07 Move to replacement deployment](#s-07-move-to-replacement-deployment)
- [S-08 Sponsor repaid at execution](#s-08-sponsor-repaid-at-execution)
- [S-09 Pause stops suspect recovery](#s-09-pause-stops-suspect-recovery)
- [S-10 Recovery through a stop](#s-10-recovery-through-a-stop)
- [S-11 Identity method key rotation](#s-11-identity-method-key-rotation)
- [S-12 Identity method role handover](#s-12-identity-method-role-handover)
- [S-13 Other authorities on the account](#s-13-other-authorities-on-the-account)

## S-01 Set up recovery

**Goal.** I still hold my key, and I want a way back into my account if I ever lose it, set up in one go.

**Actors.** the holder, whoever sends the transaction (the holder or anyone), the manager, the action.

**Given**

- An Ambire account on the pinned implementation, the holder's key at privilege 2, and no setup for the action.
- Maya's rule, written off chain with an encrypted backup. Clause 0 needs any 2 of Ana (place 0), Ben (place 1) and Carla (place 2), each a wallet guardian on the wallet method. Clause 1 needs any 1 of Maya's hardware wallet (place 3, wallet method) and Maya's passkey (place 4, passkey method). Both clauses must hold. The wait is 5 days, ignoresPause is false, and each place carries the default salt keccak256(account, place).

**Runs for each of**

- the holder signs and a relayer sends it to account.execute
- the holder sends it from the key (executeBySender)
- an ERC-4337 operation sponsored by a paymaster
- an account not yet deployed, which Ambire's factory deploys and runs the batch for in one transaction

**Walk**

1. The holder signs one batch, setAddrPrivilege(KIT_SLOT, binding) then commitSetup(action, commitment, 1, no public metadata, encrypted backup).
2. The holder, or anyone, sends the batch.

**Then**

- The holder's key is still the account's only key, and an ordinary transfer it signs runs as before.
- The action is authorized and the setup is stored, so a recovery works from here (S-02).

**Even if**

- The batch names an action that does not serve the account (another implementation, or an address delegating to Ambire code under EIP-7702). commitSetup reverts, the whole batch reverts and KIT_SLOT stays empty. (D-103, D-105)

**Tradeoffs**

- The contract accepts a wait of zero, and an attempt under such a setup is spent in the block that opened it. (D-103, D-107)

**Tests**

- `test/integration/SetUpRecovery.t.sol`: `test_WhenTheHolderSetsUpRecoveryInOneBatch`
- `test/integration/SetUpRecovery.t.sol`: `test_WhenTheAccountRunsAnotherImplementation`
- `test/integration/SetUpRecovery.t.sol`: `test_WhenTheHoldersAddressDelegatesToAmbireCode`
- `test/integration/SetUpRecovery.t.sol`: `test_WhenTheRuleHasNoWait`

## S-02 Recover lost key with approvers

**Goal.** I lost my only key; I want my friends and my backup device to hand my account to a new key, and then I want a fresh path the published rule cannot use.

**Actors.** the holder with a new key, the guardians Ana Ben and Carla, the holder's passkey, whoever submits, anyone who executes, the old helpers.

**Given**

- The account is armed with Maya's rule (S-01). The holder's key is lost, and the new key holds nothing on the account.
- Ana does not answer. The payment order is empty.

**Runs for each of**

- guardians with plain accounts, or a guardian that is a smart wallet answering with ERC-1271
- Maya's clause filled by the passkey (place 4) or by the hardware wallet (place 3)
- submitted from the new key funded by the holder, from a friend's wallet, or as a paymaster-sponsored ERC-4337 operation

**Walk**

1. The holder builds the request off chain, handing the account from the lost key to the new key, with no payment, valid for 24 hours.
2. Ben signs the approval for place 1.
3. Carla signs the approval for place 2.
4. The holder signs the approval for place 4 with the passkey.
5. Someone sends startAttempt with places 1, 2 and 4.
6. Five days pass.
7. Anyone sends executeHandover. In one transaction the account spends the attempt, adds the new key and removes the lost key.

**Then**

- The new key controls the account. The lost key holds nothing, and a batch it signs reverts.
- Nobody was paid.

**Second walk: the new key replaces the published rule**

1. Starting from the recovered account, the holder commits a new setup with other helpers, signed by the new key.
2. The old helpers sign a request handing the account to a key of theirs and send it.

Then:

- The new key, though at privilege 1, could change the rule, and the old rule, which the recovery made public, opens nothing.
- The docstring says that adopting a replacement identity method is this same commit with other credentials.

Runs for each of:

- the same helpers, recommitted under fresh salts

**Even if**

- The request's validUntil passes during the wait, and the accepted attempt still executes. (D-103)
- A batch built by hand for account.execute that adds a call, writes the new key at privilege 2 or removes another key is refused by the account's callback, and the attempt keeps waiting. (D-105)
- An ERC-4337 operation with an empty signature, sponsored by a paymaster and carrying the kit's batch, reaches the same callback and runs only the approved batch, even on an account that never turned ERC-4337 on. (D-105)

**Tradeoffs**

- The execution can land in the first block after the wait, sent by anyone. The holder does not choose when. (D-103)
- The new key sits at privilege 1, so the account refuses its unwrapped plain-message and typed-data signatures until the wallet wraps them. (D-105, D-108)
- Until the second walk, the old rule is live and public, and its helpers can open a new attempt at once. (D-110)
- Recommitting the identical published rule under the next nonce kills the old approvals, but the old helpers sign fresh ones over the public rule and open an attempt. Only a changed rule or fresh salts protect the holder. (D-103, D-110)
- Under default salts, anyone who knows a guardian's address recomputes that guardian's credential from the rule the opening published and learns they are a guardian, though they never approved. (D-110)

**Tests**

- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenTheApproversHandTheAccountToANewKey`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenTheNewKeyReplacesThePublishedRule`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenTheSameApproversSignUnderFreshSalts`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenTheNewKeyRecommitsThePublishedRule`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenAGuardianWithADefaultSaltIsRevealed`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenTheWindowPassesDuringTheWait`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_RevertWhen_AHandBuiltBatchChangesTheHandover`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenAPaymasterSponsoredOperationRunsTheBatch`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenAnyoneExecutesInTheFirstBlockAfterTheWait`
- `test/integration/RecoverLostKeyWithApprovers.t.sol`: `test_WhenTheNewKeySignsAnUnwrappedMessage`

## S-03 Owner cancels unwanted recovery

**Goal.** Someone started a recovery on my account that I never asked for. I still hold my key and I want it stopped.

**Actors.** Bob with his key, an attacker holding Bob's passkey and hardware wallet.

**Given**

- Bob's rule is one clause, any 2 of his passkey (place 0), his hardware wallet (place 1) and his passport (place 2), with a 48-hour wait.
- The attacker holds Bob's bag with the synced passkey and the hardware wallet.

**Runs for each of**

- Bob signs and a relayer sends to account.execute
- Bob sends it from his key (executeBySender)
- an ERC-4337 operation

**Walk**

1. The attacker signs approvals at places 0 and 1 handing the account to the attacker's key, and sends startAttempt.
2. Some hours pass.
3. Bob's account sends cancelByOwner(action, attempt id).
4. 48 hours pass, and the attacker sends executeHandover. It reverts.
5. Bob commits a new setup without the stolen credentials, in its own transaction.
6. The attacker signs a new request with the passkey and the hardware wallet and sends it. It fails.

**Then**

- The attacker's attempt was cancelled and its execution reverted.
- Bob's key is still the only key on the account.
- Under the new rule, the stolen credentials open nothing.

**Even if**

- Bob's cancel and the attacker's execute land in the same block after the wait. Whichever comes first wins, and both orders are tested. (D-103)

**Tradeoffs**

- Right after the cancel, the attacker reopens at the next id with the same credentials. Each attempt costs Bob one cancel until he changes the rule. (D-103)
- cancelByOwner names the attempt id, so a signed cancel ends only the attempt it names, the holder's own included, and the same bytes sent again later end nothing else. (D-103)
- A thief who finds a lost key of the account cancels every honest recovery as it opens, and a keyless holder cannot win. The kit defends against loss, not theft. (D-103, D-105)
- Nothing expires: a holder who starts a recovery, finds the old key and forgets the attempt sees it executed a year later by whoever holds the new key's device, which removes the key the holder still uses. Meanwhile the attempt holds the slot, and the payee of its order gains by leaving it. The test waits a year. (D-103, D-110)
- A signed request that leaks can be sent by anyone until its window ends, and a keyless holder cannot retire it. (D-107, D-110)

**Tests**

- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenTheHolderCancelsAndReplacesTheRule`
- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenTheCancelComesBeforeTheSpend`
- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenTheSpendComesBeforeTheCancel`
- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenTheAttackerReopensAfterTheCancel`
- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenTheCancelMeetsTheHoldersOwnAttempt`
- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenAThiefWithALostKeyCancelsEveryRecovery`
- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenNobodyCancelsAForgottenAttempt`
- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenALeakedRequestIsSentByAnyone`
- `test/integration/OwnerCancelsUnwantedRecovery.t.sol`: `test_WhenARevertedCancelIsSentAgainForALaterAttempt`

## S-04 Guardians cancel hostile recovery without key

**Goal.** I lost my key and a recovery I do not want is running. My helpers cancel it without my key, and then I recover to a key I hold.

**Actors.** the keyless holder, two honest guardians (places 2 and 3), an attacker controlling two other guardians (places 0 and 4), a friend with a funded wallet, a front-runner.

**Given**

- The rule is one clause, any 2 of five wallet guardians at places 0 to 4, with a 5-day wait and default salts. The attacker controls places 0 and 4.

**Runs for each of**

- helpers with plain accounts
- a helper that is a smart wallet

**Covers the cases where**

- an attacker opened the attempt
- the holder opened it and lost the new key's device before executing
- two satisfying sets race for the same attempt id

**Walk**

1. The attacker opens attempt N with places 0 and 4, handing the account to the attacker's key.
2. The guardians at places 2 and 3 sign the cancellation of attempt N. With default salts they build it without the holder's backup: each rebuilds their own config and salt and finds their place in the published body, and their places alone satisfy every clause. This fails under salts the holder chose, for passkey or identity credentials, and when a clause needs one of the holder's devices. (D-110)
3. The friend sends cancelByProofs.
4. The wait passes, and the attacker sends executeHandover. It reverts.
5. The guardians at places 2 and 3 sign approvals for attempt N+1 handing the account to the holder's new key, and the friend sends startAttempt.
6. Five full days pass.
7. Anyone sends executeHandover.

**Then**

- The attacker's attempt was cancelled and its execution reverted.
- Attempt N+1 ran its own full wait, and the holder's new key controls the account.

**Even if**

- cancelByProofs and the attacker's executeHandover land in the same block after the wait, and the second one reverts. (D-103)
- While N waits, another satisfying set sends its request for the same id, and it reverts, since one attempt runs at a time. (D-103)
- A front-runner copies the request for N+1 from the mempool and sends it first. The attempt opens with the handover and the payee the guardians signed, whoever sent it. (D-103)

**Tradeoffs**

- Right after the cancel, the attacker reopens at N+1 and the honest set must cancel again. Each round costs gas, and a keyless holder cannot end the cycle. The test shows two rounds. (D-110)
- The first satisfying set holds the slot for the whole wait. The other set can only cancel and send again, two transactions and a new wait. (D-103)
- Honest guardians can pre-sign cancels for N+1, N+2 and on. Each cancels whatever opens at that id, the holder's own recovery included, and carries its own validUntil and the setup nonce, so it does not last forever. (D-103, D-110)
- A rule where the honest side cannot form a satisfying set leaves no cancel without the key. (D-110)
- Whoever sends a cancel pays its gas, and nothing repays it. (D-103)

**Tests**

- `test/integration/GuardiansCancelHostileRecoveryWithoutKey.t.sol`: `test_WhenTheGuardiansCancelAndRecover`
- `test/integration/GuardiansCancelHostileRecoveryWithoutKey.t.sol`: `test_WhenTheCancelAndTheSpendLandInOneBlock`
- `test/integration/GuardiansCancelHostileRecoveryWithoutKey.t.sol`: `test_RevertWhen_ASecondSetOpensTheSameId`
- `test/integration/GuardiansCancelHostileRecoveryWithoutKey.t.sol`: `test_WhenAFrontRunnerCopiesTheRequest`
- `test/integration/GuardiansCancelHostileRecoveryWithoutKey.t.sol`: `test_WhenTheAttackerReopensAfterEachCancel`
- `test/integration/GuardiansCancelHostileRecoveryWithoutKey.t.sol`: `test_WhenACancelSignedAheadMeetsTheHoldersOwnAttempt`
- `test/integration/GuardiansCancelHostileRecoveryWithoutKey.t.sol`: `test_RevertWhen_TheGuardiansLeftCannotSatisfyTheRule`

## S-05 Edit setup while recovery runs

**Goal.** I still hold my key and I want to change my helpers. If a recovery is running, my edit must kill it along with every approval given so far.

**Actors.** the holder with the key, an attacker with a waiting attempt and old approvals.

**Given**

- Attempt N waits under setup nonce 1. The attacker also holds a satisfying set of approvals signed under nonce 1 for id N+1.

**Walk**

1. The holder sends commitSetup with the identical body under nonce 2.
2. The attacker sends the request for N+1 signed under nonce 1. It fails.
3. The wait passes, and the attacker sends executeHandover for N. It reverts.

**Then**

- Attempt N was cancelled in the edit's own transaction, and every approval signed before it is dead though the rule is identical.

**Even if**

- The holder clears and then recommits the very same body, and proofs from before the clear still fail. (D-103)
- The edit and the attacker's execute land in the same block after the wait. Whichever comes first wins; if the execute is first, the account is handed over. (D-103)

**Tradeoffs**

- An edit takes effect at once, with no wait and no notice. Whoever holds the account key, a thief included, can replace the setup silently. Authorized contracts can too (S-13). (D-103)

**Tests**

- `test/integration/EditSetupWhileRecoveryRuns.t.sol`: `test_WhenTheHolderRewritesTheIdenticalRule`
- `test/integration/EditSetupWhileRecoveryRuns.t.sol`: `test_WhenTheHolderClearsAndRecommitsTheSameRule`
- `test/integration/EditSetupWhileRecoveryRuns.t.sol`: `test_WhenTheEditComesBeforeTheSpend`
- `test/integration/EditSetupWhileRecoveryRuns.t.sol`: `test_WhenTheSpendComesBeforeTheEdit`
- `test/integration/EditSetupWhileRecoveryRuns.t.sol`: `test_WhenAThiefReplacesTheRule`

## S-06 Turn recovery off and on

**Goal.** I want recovery turned off on my account, and maybe back on later.

**Actors.** the holder with the key, an attacker with a satisfying set, the attacker's bot, anyone holding an old signed request.

**Given**

- The account is armed with Maya's rule.

**Walk**

1. The holder sends one batch, clearSetup(action, nonce) then setAddrPrivilege(KIT_SLOT, 0).
2. Someone sends an old signed request. It fails.
3. Months pass.
4. The holder sends one batch, setAddrPrivilege(KIT_SLOT, binding) then commitSetup under the next nonce.
5. The helpers recover the account under the new setup.

**Then**

- After the disarm no request opens anything, and account.execute with the kit's signature reverts.
- After the rearm a recovery works, and the attempt id continues where it was rather than restarting at 1.

**Second walk: the holder only uninstalls the kit, without clearSetup**

1. The holder writes setAddrPrivilege(KIT_SLOT, 0) without clearSetup.
2. The attacker opens an attempt, which the live setup accepts.
3. The wait passes, and the attacker's executeHandover reverts, since the account has no binding.
4. Months later the holder writes the binding back alone, without commitSetup.
5. The attacker's bot sends executeHandover in the next block.

Then:

- The account passes to the attacker with none of the notice window left. Nothing tells the manager that the authorization was removed. (D-103, D-110)

Runs for each of:

- a wallet that committed the setup and never wrote the binding

**Even if**

- An attempt was waiting when the holder disarmed, and it is cancelled. (D-103)
- clearSetup alone, with KIT_SLOT still set, leaves nothing spendable, and a single commitSetup later rearms. (D-110)

**Tradeoffs**

- The second walk is an accepted outcome as a whole. (D-110)

**Tests**

- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenTheHolderTurnsRecoveryOffAndOn`
- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenTheHolderUninstallsTheKitWithoutClearing`
- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenTheSetupWasCommittedWithoutTheBinding`
- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenTheRebindIsPairedWithACommit`
- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenTheHolderCancelsBeforeRebinding`
- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenApprovalsGatheredBeforeTheUninstallStillOpen`
- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenAnAttemptWaitsAsRecoveryIsTurnedOff`
- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenTheHolderClearsButKeepsTheBinding`
- `test/integration/TurnRecoveryOffAndOn.t.sol`: `test_WhenAClearThatRevertedIsSentAgainAfterANewCommit`

## S-07 Move to replacement deployment

**Goal.** A fix shipped as a new manager. I want to move my recovery over while I still hold my key, without leaving the old one live.

**Actors.** the holder with the key, the helpers, an attacker with a credential the old rule accepts.

**Given**

- The account is armed on the old manager with the old action. The new manager and its new action are deployed.
- This is its own scenario because other contracts take part, another manager with another signing domain and another action under another KIT_SLOT. Adopting a replacement method on the same manager is a recommit, covered by the second walk of S-02.

**Walk**

1. The holder sends one batch of four calls, zeroing the old action's KIT_SLOT, clearSetup on the old manager, writing the new action's binding, and commitSetup on the new manager.
2. The helpers recover the account on the new manager, as in S-02.

**Then**

- The recovery on the new manager works, and the helpers' request at the old manager opens nothing.

**Second walk: two setups stay live at once**

1. The holder arms the new pair without clearing the old setup or zeroing the old binding.
2. The attacker opens an attempt on the old manager with a credential the old rule accepts and the new rule dropped.
3. The holder's cancelByOwner on the new manager reverts, since nothing waits there, and the old manager's attempt keeps waiting.
4. The wait passes, and the attacker executes through the old action.

Then:

- The account is the attacker's, unless the holder cancels on the old manager. (D-106)

Runs for each of:

- a second recovery action on the same manager, each action with its own KIT_SLOT and its own setup

**Tradeoffs**

- The contracts allow a live setup on each manager at once (second walk). The setup screen refuses it, but only for deployments the client knows. (D-106)
- A keyless holder cannot migrate. (D-106)

**Tests**

- `test/integration/MoveToReplacementDeployment.t.sol`: `test_WhenTheHolderMigratesInOneBatch`
- `test/integration/MoveToReplacementDeployment.t.sol`: `test_WhenTwoSetupsStayLive`
- `test/integration/MoveToReplacementDeployment.t.sol`: `test_WhenTwoActionsShareOneManager`

## S-08 Sponsor repaid at execution

**Goal.** I pay the gas for a friend with no funded key, and I want their account to repay me when the recovery lands.

**Actors.** the keyless holder, the helpers, the sponsor, a relayer, a bot that executes.

**Given**

- The account is armed with Maya's rule and holds 100 USDC and some ETH. The holder agreed with the sponsor on an order of 10 USDC to the sponsor.

**Runs for each of**

- a named payee with an ERC-20 token
- a named payee with native ETH
- an open payee (the zero address), which pays whoever calls executeHandover

**Walk**

1. The holder builds the request with the order, and Ben, Carla and the passkey sign approvals that include it.
2. The relayer sends startAttempt on the sponsor's behalf, or the sponsor's paymaster sponsors the operation.
3. Five days pass.
4. A bot that copied the pending execute transaction sends executeHandover first.

**Then**

- The handover is done and the sponsor received 10 USDC, though the bot sent the transaction. With an open payee, whoever called executeHandover was paid.

**Even if**

- The account lacks the 10 USDC at execution. The batch reverts and the attempt keeps waiting, and once funded the same call succeeds. (D-103)
- Nobody can redirect the payment by sending the batch straight to account.execute: a batch with the approved handover but another payee or another amount is refused by the account's callback, and the attempt keeps waiting. (D-105)
- A three-call batch that drops the payment of an order with an amount is refused. (D-105)
- Re-entrancy: a payee contract that receives the ETH, calls the account again with the same batch and catches the failure finds the approval spent, so the nested run reverts and the handover completes once. A payee that lets the failure bubble up is the reverting payee below. (D-105)

**Tradeoffs**

- A token that returns false, a token address with no code, or a token address whose fallback swallows the call (the Ambire account is one) completes the handover with nobody paid. (D-110)
- A batch built by hand for an open native order that names the zero address as payee makes the account skip that call, so the handover lands and nobody is paid. (D-105, D-110)
- A named payee that reverts on receipt holds the attempt hostage until the holder's key, a cancel set or a veto ends it, and meanwhile no other set can open. A keyless holder clears it by cancel by proofs and opens the next id; the test shows it. (D-110)
- An attempt cancelled during its wait leaves the sponsor who paid for the opening unpaid. (D-107)
- The price is fixed at signing and paid days later. A stale price is repaired only by a cancel and a fresh attempt. (D-107)

**Tests**

- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_WhenABotExecutesAndTheSponsorIsPaid`
- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_WhenTheAccountIsShortOfTheToken`
- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_RevertWhen_ABatchSentToTheAccountDivertsThePayment`
- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_RevertWhen_ABatchDropsThePayment`
- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_WhenThePayeeReentersWithTheSameBatch`
- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_WhenTheTokenPaysNobody`
- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_WhenAnOpenNativeOrderNamesTheZeroPayee`
- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_WhenTheNamedPayeeRevertsAndHoldsTheSlot`
- `test/integration/SponsorRepaidAtExecution.t.sol`: `test_WhenTheAttemptIsCancelledAndTheSponsorIsUnpaid`

## S-09 Pause stops suspect recovery

**Goal.** A bug in an identity method may be forging proofs. As the pause holder, I want every recovery that leans on it stopped until we know.

**Actors.** the pause holder (the deployment's Safe), an attacker, anyone, the holder.

**Given**

- The holder's rule is any 3 of 4, one credential per method: a wallet (place 0), Aadhaar (place 1), a passport through zkPassport (place 2) and a passkey (place 3). The wait is 5 days and ignoresPause is false.
- The attacker holds the wallet and forges the Aadhaar and passport proofs.

**Runs for each of**

- method-aadhaar stopped, the middle of the attempt's used methods (ecdsa, aadhaar, zkpassport)
- method-zkpassport stopped, the last of them

**Walk**

1. The attacker sends startAttempt with places 0, 1 and 2.
2. The pause holder sends pause() on method-aadhaar.
3. The wait passes, and the attacker sends executeHandover. It reverts, since the stopped method vetoes the spend though the first used method (ecdsa) has no pause.
4. Anyone sends cancelByVeto naming attempt N and method-aadhaar.
5. The pause holder sends unpause().

**Then**

- The attempt was cancelled by veto, stays cancelled after the lift, and the account is unchanged.

**Second walk: nobody vetoes before the unpause**

1. The attacker opens the attempt and the pause holder stops method-aadhaar.
2. The wait passes, and the attacker's execute reverts.
3. The pause holder lifts the stop with nobody having sent cancelByVeto.
4. The attacker sends executeHandover.

Then:

- The account is the attacker's in the block after the lift, with no notice window left. A stop refuses the spend; only a veto ends the attempt. (D-111)

**Even if**

- cancelByVeto sent during the wait, before it ends, works too, since a veto needs no wait. (D-103)
- With method-aadhaar stopped, a request that leaves its place out and fills the clause with other methods opens. (D-111)

**Tradeoffs**

- A veto ends honest attempts too, and their helpers sign again after the lift. (D-111)
- The pause holder can aim pause, veto and unpause at one holder's attempt. A submitter can add a surplus place of a pausable method to expose an attempt to that, or a front-runner can send a subset of the proofs and change which methods can veto. (D-103, D-110)
- A keyless holder whose clause needs the stopped method waits for the lift, and a pause holder who renounces while stopped strands them for good. (D-111)
- A compromised pause holder can stop recoveries for good. (D-111)

**Tests**

- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenTheStoppedMethodIsTheMiddleOfTheUsedMethods`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenTheStoppedMethodIsTheLastUsedMethod`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenNobodyVetoesBeforeTheUnpause`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenTheVetoComesDuringTheWait`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenARequestLeavesTheStoppedMethodOut`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenTheStopEndsTheHoldersOwnAttempt`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenThePauseHolderTargetsOneAttempt`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenAKeylessHolderWaitsForTheUnpause`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenAFrontRunnerSubmitsASubsetAndAUsedMethodIsStopped`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenAFrontRunnerSubmitsASubsetAndAnUnusedMethodIsStopped`

## S-10 Recovery through a stop

**Goal.** I chose at setup that a security stop must not hold up my recovery.

**Actors.** Diana without her key, the pause holder, anyone who tries to veto.

**Given**

- Diana's rule is any 1 of her passkey (place 0) and her passport through zkPassport (place 1), with a 48-hour wait and ignoresPause true.

**Runs for each of**

- the stop on before the opening
- the stop turned on during the wait

**Walk**

1. The pause holder stops method-zkpassport.
2. Diana proves her passport for place 1 and sends startAttempt.
3. 48 hours pass.
4. Diana sends executeHandover.

**Then**

- The attempt opened and executed through the stop, and Diana's new key controls the account.

**Second walk: one stop over several holders**

1. On one manager three attempts open: one that used zkPassport and keeps stops on, one that used zkPassport and ignores stops, and one whose rule names zkPassport but whose attempt did not use it.
2. The pause holder stops method-zkpassport.
3. The wait passes, and someone sends executeHandover on all three accounts.
4. Someone sends cancelByVeto on the first attempt.

Then:

- The first attempt's spend is refused and anyone ends it by veto. The second spends anyway. The third spends, since only the methods an attempt used can stop it. (D-111, D-103)

**Even if**

- Someone sends cancelByVeto naming the stopped method, and it fails, since the setup ignores stops. (D-103, D-111)
- A cancel by proofs that leans on the stopped method works for this holder. (D-110)

**Tradeoffs**

- A forged recovery through the stopped method passes too, and nobody can veto it. (D-111)

**Tests**

- `test/integration/RecoveryThroughAStop.t.sol`: `test_WhenTheHolderRecoversThroughAStop`
- `test/integration/RecoveryThroughAStop.t.sol`: `test_WhenOneStopMeetsSeveralHolders`
- `test/integration/RecoveryThroughAStop.t.sol`: `test_RevertWhen_SomeoneVetoesAnOptedOutAttempt`
- `test/integration/RecoveryThroughAStop.t.sol`: `test_WhenTheHolderCancelsThroughTheStop`
- `test/integration/RecoveryThroughAStop.t.sol`: `test_WhenAForgedProofPassesThroughTheStop`

## S-11 Identity method key rotation

**Goal.** The Aadhaar issuer rotated its key. As the key admin, I want the helpers' fresh QR codes to verify again.

**Actors.** the key admin (a Safe), an Aadhaar helper, the holder.

**Given**

- A holder's rule names an Aadhaar credential. The issuer has just rotated its signing key.

**Runs for each of**

- method-aadhaar: the issuer key hash is replaced
- method-zkpassport: the accepted version moves, and a committed identifier keeps matching while the derivation is unchanged

**Walk**

1. The holder sends a request whose Aadhaar proof comes from a QR signed under the new key. It fails.
2. The key admin sends setTrustedKeys with the new issuer hash.
3. The helper downloads a fresh QR and proves over the digest, and the holder's request opens.

**Then**

- Proofs under the new issuer key verify and the holder's request opens.

**Even if**

- An attempt accepted before the rotation still executes, since it is not judged again. (D-110)

**Tradeoffs**

- The Aadhaar key admin can set a key it controls and forge a proof for any digest. A holder whose rule rests on that method alone loses the account, and the same forgery fills cancels. The zkPassport key admin cannot do the same through the router, since the method fixes its root verifier at deployment and refuses a list that names another, so forging a zkPassport proof needs zkPassport's own root admin or guardian. (D-104, D-110)
- A rotation during a wait removes honest cancels that lean on the method, while the hostile attempt stands. (D-110)
- A zkPassport release that changes the identifier derivation strands committed credentials once the version moves. (D-110)

**Tests**

- `test/integration/IdentityMethodKeyRotation.t.sol`: `test_WhenTheKeyAdminRotatesTheIssuerKey`
- `test/integration/IdentityMethodKeyRotation.t.sol`: `test_WhenAnAcceptedAttemptOutlivesTheRotation`
- `test/integration/IdentityMethodKeyRotation.t.sol`: `test_WhenTheKeyAdminForgesAProof`
- `test/integration/IdentityMethodKeyRotation.t.sol`: `test_WhenTheKeyAdminTriesToRouteProofsToARootVerifierItControls`
- `test/integration/IdentityMethodKeyRotation.t.sol`: `test_WhenARotationRemovesTheGuardiansCancel`

## S-12 Identity method role handover

**Goal.** As the Safe that holds a role of an identity method (key admin or pause holder), I want to hand the role to another Safe with never zero or two holders, and the new one must be able to use it.

**Actors.** the Safe holding the role, the new Safe, an Aadhaar helper, the holder.

**Given**

- As in S-11, a holder's rule names an Aadhaar credential.

**Walk**

1. The key admin sends transferAdmin to offer the role to the new Safe.
2. The new Safe sends acceptAdmin.
3. The issuer rotates its key, and the new admin sends setTrustedKeys. It works, and the holder's request with a fresh QR opens.
4. The old admin sends setTrustedKeys. It fails.

**Then**

- The role had exactly one holder at every moment, and the new one keeps the keys current.

**Second walk: the pause holder hands on the role**

1. The pause holder offers the role to the new Safe, and the new Safe accepts.
2. The new Safe stops the method, and the holder's request with an Aadhaar proof is refused.
3. The new Safe lifts the stop, and the request opens.
4. The old pause holder tries to stop the method. It fails.

Then:

- The pause role had exactly one holder at every moment, and the new one can stop and lift. (D-111)

**Tradeoffs**

- After renounceAdmin nobody can rotate, so the issuer's next rotation strands every Aadhaar credential with no fix for a keyless holder. (D-104, D-110)

**Tests**

- `test/integration/IdentityMethodRoleHandover.t.sol`: `test_WhenTheKeyAdminHandsOnTheRole`
- `test/integration/IdentityMethodRoleHandover.t.sol`: `test_WhenThePauseHolderHandsOnTheRole`
- `test/integration/IdentityMethodRoleHandover.t.sol`: `test_WhenTheKeyAdminRenounces`

## S-13 Other authorities on the account

**Goal.** My account has several keys and other contracts besides the kit. I want to recover only the key I lost and leave the rest as they are.

**Actors.** the helpers, the holder with two keys on two devices (the phone and the laptop), another validator bound under its own slot, anyone who executes.

**Given**

- The account holds the phone's key and the laptop's key, both at privilege 2, and another validator under its own slot. It is armed with Maya's rule.
- An Ambire account's keys each sign alone; there is no threshold multisig. Rotating keys one at a time is replacing one privilege entry at a time. (D-105)

**Walk**

1. The holder loses the laptop. The helpers open an attempt handing the account from the laptop's key to a new key.
2. Five days pass, and anyone sends executeHandover.

**Then**

- The laptop's key is gone and the new key is in. The phone's key still signs an ordinary batch, and the other validator and KIT_SLOT are untouched.

**Tradeoffs**

- One handover moves one key. If the phone was lost too, the new key removes the phone's key with an ordinary account write; a second recovery would only add a wait. (D-105)
- While the other key stays on the account, whoever holds it can cancelByOwner or clear the setup. If it sat on the same stolen device, the thief stops the recovery. (D-105)
- The other validator sends consume alone, so the approval is spent and nothing is installed. (D-102)
- The other validator or the other key zeroes the lost key during the wait, so the committed handover no longer passes and the attempt is stuck until a cancel. (D-105)
- Any contract the account authorized can call commitSetup, clearSetup, cancelByOwner and consume for every action of the account. (D-110)
- On an account that bound the action under another slot, a handover approved with KIT_SLOT as the new key installs a key nobody can sign for. It needs its own fixture and a hand-built execute. (D-105)

**Tests**

- `test/integration/OtherAuthoritiesOnTheAccount.t.sol`: `test_WhenTheHolderRecoversOneOfTwoKeys`
- `test/integration/OtherAuthoritiesOnTheAccount.t.sol`: `test_WhenTheNewKeyRemovesTheOtherLostKey`
- `test/integration/OtherAuthoritiesOnTheAccount.t.sol`: `test_WhenTheOtherKeyCancelsTheRecovery`
- `test/integration/OtherAuthoritiesOnTheAccount.t.sol`: `test_WhenAnotherValidatorConsumesAlone`
- `test/integration/OtherAuthoritiesOnTheAccount.t.sol`: `test_WhenAnotherAuthorityZeroesTheLostKey`
- `test/integration/OtherAuthoritiesOnTheAccount.t.sol`: `test_WhenAnAuthorizedContractReplacesTheRule`
- `test/integration/OtherAuthoritiesOnTheAccount.t.sol`: `test_WhenTheKitSlotIsApprovedAsTheNewKey`
