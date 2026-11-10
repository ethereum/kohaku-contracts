# Invariants

Each invariant is a property of the contracts that must hold after every call, whatever the caller sends. Where a scenario in [`scenarios.md`](scenarios.md) says what happens in order, an invariant says what must never be false. Each one names the class of bug it rules out and the tests that check it. Section ids such as D-103 point to [`contracts.md`](contracts.md).

The ids are not consecutive: the gaps are properties of the SDK and the wallet's screens, which live outside this repository.

## Index

- [I-1](#i-1): key rotation only ever happens through a path the holder set up
- [I-2](#i-2): only the account's own authority changes the recovery configuration
- [I-3](#i-3): a method you never named cannot recover your account, a corollary of I-1
- [I-4](#i-4): the method you approved is the method that runs, a corollary of I-1
- [I-5](#i-5): anyone can build a method, any holder can adopt one, nobody gatekeeps
- [I-6](#i-6): an attempt completes only after the wait the holder set has elapsed
- [I-7](#i-7): the current key can always cancel a running recovery
- [I-8](#i-8): a cancel needs what the recovery needed, and anyone may send it
- [I-9](#i-9): no complete proof set, no recovery, no ticking clock
- [I-10](#i-10): at most one attempt per action at a time, so at most one recovery
- [I-11](#i-11): a proof made for one recovery is useless for any other
- [I-12](#i-12): editing a setup retires every proof already given, even when the edited setup rewrites the identical rule
- [I-13](#i-13): a proof past its window opens nothing
- [I-14](#i-14): methods are independent, one failing or hostile method never touches another
- [I-16](#i-16): the chain learns only what the holder chose to show
- [I-17](#i-17): the lost key cannot take the account back after recovery
- [I-18](#i-18): an approved handover executes at most once and exactly as committed, spent and applied as one atomic batch, nothing more
- [I-19](#i-19): a pause only refuses, it never lets a recovery through
- [I-49](#i-49): only the current key admin re-keys an identity method, and only the current pause holder stops it
- [I-20](#i-20): every setup write and every recovery step emits its event, no event lies
- [I-21](#i-21): the wallet app and the policy manager always build a shared message the same way, so the approval Ana signs on her phone is the approval the contract accepts
- [I-22](#i-22): the approval a helper's app produces is exactly the approval the method module expects, so a yes gathered off chain never turns into a rejection on chain

## I-1

**In short.** Key rotation only ever happens through a path the holder set up.

**Property.** The policy manager approves and releases a recovery only under a setup the holder committed, every requirement of that setup met in full.

**Rules out.** Policy bypass, unauthorized recovery path.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_aReleaseMeetsEveryRequirementOfTheCommittedSetup`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheAttemptIdIsNotTheLiveOne`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenThePayloadHashIsNotTheCommittedOne`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenANewSetupEndedTheAttempt`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheAttemptWasJudgedUnderAnotherNonce`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenAnotherAddressCalls`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheWaitIsOverAndNoUsedMethodVetoes`

## I-2

**In short.** Only the account's own authority changes the recovery configuration.

**Property.** Only the account's current authority creates, changes or removes setups, whenever that authority holds and no other write of the same account has moved the nonce the write names. The policy manager accepts configuration writes from the account alone.

**Rules out.** Configuration takeover.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_onlyTheAccountChangesItsSetup`
- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_acceptedWritesNameTheNextNonce`
- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_oneEventPerWriteAndTheCancelFirst`
- `test/policy-manager/PolicyManagerCommitSetup.t.sol`: `test_WhenAnAddressOtherThanTheAccountCalls`
- `test/policy-manager/PolicyManagerClearSetup.t.sol`: `test_WhenAnAddressOtherThanTheAccountCalls`
- `test/policy-manager/PolicyManagerCommitSetup.t.sol`: `test_WhenTheNonceIsNotTheCurrentOnePlusOne`

## I-3

**In short.** A method you never named cannot recover your account, a corollary of I-1.

**Property.** A method the holder's committed rule never names cannot contribute to satisfying that holder's recovery.

**Rules out.** Unauthorized method participation.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_unnamedMethodsNeverCount`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenAProofNamesAMethodTheRuleNeverNames`
- `test/policy-manager/PolicyManagerCancelByProofs.t.sol`: `test_WhenAProofNamesAMethodTheRuleNeverNames`

## I-4

**In short.** The method you approved is the method that runs, a corollary of I-1.

**Property.** A holder's setup pins each credential's exact module address inside its commitment, and the policy manager recommits that address with the credential's config and salt before every dispatch, so the module the holder named is the module that runs, always, on the stated assumption that code at a committed address stays what the holder inspected. The cases where it does not are out of scope by decision. A module that routes its logic elsewhere through indirection keeps its committed address while its behavior moves, a risk shown at adoption as the adopter's own. A module without a declaration of trusted parties still runs at exactly the address the holder named, only the declaration of its trusted parties waived.

**Rules out.** Proxy swap under a committed address.

**Contracts.** `PolicyManager`, `EcdsaMethod`, `PasskeyMethod`, `AadhaarMethod`, `ZkPassportMethod`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_theCommittedModuleIsTheOneThatRuns`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheProofNamesAnotherMethodOfTheRule`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheProofCarriesAnotherConfig`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheProofCarriesAnotherSalt`
- `test/policy-manager/PolicyManagerCancelByProofs.t.sol`: `test_WhenTheProofNamesAnotherMethodOfTheRule`

## I-5

**In short.** Anyone can build a method, any holder can adopt one, nobody gatekeeps.

**Property.** Deploying a method module requires nobody's permission. A holder adopts any module by naming it in their rule, with no allowlist, registry gate or privileged set standing between. The shipped methods are ordinary instances with no special powers. A method may carry a pause of its own, which stops that method's proofs after adoption until whoever holds it lifts it, for every holder whose setup did not commit to ignore stops, the pause D-111 specifies, and gates nothing before it.

**Rules out.** Gatekept extensibility, privileged method set.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_anyMethodWorksWithoutPermission`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenAMethodReportsItselfStopped`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheBodyIgnoresStops`

## I-6

**In short.** An attempt completes only after the wait the holder set has elapsed.

**Property.** An attempt's approval is spent only after the waiting period its setup committed has fully elapsed since the proof set was accepted. The kit enforces no minimum, so the period is the holder's own choice committed with the rule.

**Rules out.** Wait bypass, early release.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_noSpendBeforeTheWaitHasPassed`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheWaitIsNotOver`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenOneSecondOfTheWaitIsLeft`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheWaitIsZero`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenOneSecondOfAnyWaitIsLeft`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenAnyWaitEndsThisSecond`

## I-7

**In short.** The current key can always cancel a running recovery.

**Property.** While an attempt is waiting, a cancel sent by the account's current authority succeeds at the policy manager, a call that reaches no method and that no pause can reach. What ends that attempt first, another cancel path or a setup write, makes the holder's own call revert with nothing to cancel, which is the attempt already gone rather than the holder refused. What the account installs on itself is outside the contract's reach, so a hook the same authority added can revert the account's own path, the boundary I-17 states, while the proof-set cancel of I-8 makes no account call and stays open regardless.

**Rules out.** Lockout of the legitimate holder.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_currentKeyCancels`
- `test/policy-manager/PolicyManagerCancelByOwner.t.sol`: `test_WhenTheAttemptsMethodsReportAStopOrRevertOnEveryCall`
- `test/policy-manager/PolicyManagerCancelByOwner.t.sol`: `test_WhenANewSetupAlreadyEndedTheAttempt`
- `test/policy-manager/PolicyManagerCancelByOwner.t.sol`: `test_WhenAClearAlreadyEndedTheAttempt`

## I-8

**In short.** A cancel needs what the recovery needed, and anyone may send it.

**Property.** An active attempt is also cancelled without the account's key, by a proof set that satisfies the same committed rule an opening set has to satisfy, signed for that exact attempt under the cancel purpose, and sent by anyone. The credentials filling it may belong to different people of the rule than the ones who opened the attempt. A set too weak to open a recovery cancels none by proofs, an approval never counts as a cancel, and a cancel signed for one attempt counts for no other. One cancellation reads no proofs at all, the one a stopped method authorizes, which ends an attempt that method's proofs opened and takes its authorization from that method's own answer rather than from any set, and which the manager refuses for an attempt whose setup committed to keep it through a stop. The manager refuses a stopped method's proofs here as it refuses them at an opening, unless the setup committed to ignore stops, so a cancelling set that needs a stopped method waits for the lift wherever its holder did not choose otherwise, which is why the setup screen asks for redundancy inside the clauses a cancel would use.

**Rules out.** Uncancellable hostile recovery, cancel by a set weaker than the rule.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_anAttemptEndsWithoutTheKeyOnlyByTheRuleOrAStop`
- `test/policy-manager/PolicyManagerCancelByVeto.t.sol`: `test_WhenAUsedMethodReportsAStop`
- `test/policy-manager/PolicyManagerCancelByVeto.t.sol`: `test_WhenTheAttemptIgnoresStops`
- `test/policy-manager/PolicyManagerCancelByVeto.t.sol`: `test_WhenTheMethodIsNotOneTheAttemptUsed`
- `test/policy-manager/PolicyManagerCancelByVeto.t.sol`: `test_WhenTheAttemptIdIsNotTheLiveOne`
- `test/policy-manager/PolicyManagerCancelByProofs.t.sol`: `test_WhenTheSetIsTooWeakToOpen`
- `test/policy-manager/PolicyManagerCancelByProofs.t.sol`: `test_WhenTheProofsSignTheApprovalDigest`
- `test/policy-manager/PolicyManagerCancelByProofs.t.sol`: `test_WhenAMethodReportsItselfStopped`

## I-9

**In short.** No complete proof set, no recovery, no ticking clock.

**Property.** An attempt starts, with its clock, only when the policy manager accepts a proof set meeting every clause's threshold in one transaction. Proofs are never accepted or stored one at a time. Acceptance is checked once and never regresses, so a proof expiring mid-wait undoes nothing. A rejected or incomplete request changes no account state.

**Rules out.** Clock manipulation, junk-attempt state pollution, partial-progress storage.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_attemptsOpenOnlyOnACompleteSet`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenAClauseMissesItsThreshold`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheRequestCarriesNoProofs`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheWindowPassesAfterAcceptance`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenACompleteSetIsAccepted`

## I-10

**In short.** At most one attempt per action at a time, so at most one recovery.

**Property.** At most one attempt exists per account and per committed action under one policy manager deployment at any moment, so the recovery action holds at most one. A new attempt opens only when none is active for that action, an attempt ends only by being spent or by cancellation, a finished attempt never transitions again. Two deployments holding setups for one account each hold their own, and so do two action addresses carrying one outcome, so a migration clears the old setup before the new is committed and the setup screen refuses a second setup for one outcome. Those last two are the setup screen's, checked in the SDK rather than by the fuzz this invariant names, which reaches the one attempt per account and action the manager itself enforces.

**Rules out.** Concurrent-attempt overwrite, sibling handover race, attempt resurrection.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_oneAttemptAtATimeAndEndedAttemptsStayEnded`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheSameSpendIsSentTwice`
- `test/policy-manager/PolicyManagerCancelByVeto.t.sol`: `test_WhenTheSameVetoIsSentTwice`
- `test/policy-manager/PolicyManagerCancelByVeto.t.sol`: `test_WhenTheAttemptWasConsumed`

## I-11

**In short.** A proof made for one recovery is useless for any other.

**Property.** Every proof works for exactly one attempt, on one account, for one committed action, on one chain, under one policy manager and one setup version counted by the setup nonce, filling one place in the rule under the exact credential configuration committed at that place, which a conforming method binds into its verdict rather than receiving as context, an approval proof approving one exact outcome payload with the payment order beside it and a cancel proof naming one exact attempt and no outcome. It never counts twice and never works anywhere else. Attempt ids run in sequence for each account and action and are never reused, and the manager accepts a request only when it carries the exact next id, so a proof set signed for a later id opens nothing until that id comes up. What the manager delivers unconditionally is the distinct digest, built fresh for each attempt, setup nonce, place, window and outcome, and the refusal of a repeated place. That those bytes are what a credential actually authorized rests on the method binding the digest and the configuration into its verdict, which a conforming method does and an adopted one is trusted to, the wallet method inheriting the same dependency wherever it delegates to a contract guardian.

**Rules out.** Proof replay, cross-account replay, place reuse, contract-swap replay.

**Contracts.** `PolicyManager`, `EcdsaMethod`, `PasskeyMethod`, `AadhaarMethod`, `ZkPassportMethod`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_aProofWorksForExactlyOneAttempt`
- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_attemptCounterMovesOnlyOnAnOpening`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheAttemptIdIsNotTheNextOne`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheAttemptIdWasAlreadyUsed`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheProofApprovesAnotherPayload`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenAPlaceRepeatsThePreviousOne`
- `test/policy-manager/PolicyManagerCancelByProofs.t.sol`: `test_WhenTheProofsSignTheApprovalDigest`
- `test/policy-manager/PolicyManagerCancelByProofs.t.sol`: `test_WhenTheProofsWereSignedForAnotherAttempt`
- `test/method-ecdsa/EcdsaMethodVerifyKey.t.sol`: `test_WhenTheGuardianKeySignsAnotherDigest`
- `test/method-ecdsa/EcdsaMethodVerifyContract.t.sol`: `testFuzz_RefusesWhenTheGuardianIsAskedAboutAnotherDigest`
- `test/method-passkey/PasskeyMethodVerify.t.sol`: `test_WhenVerifyIsAskedAboutAnotherDigest`
- `test/method-aadhaar/AadhaarMethodVerify.t.sol`: `test_WhenVerifyIsAskedAboutAnotherDigest`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorsUnderAnotherDigest`

## I-12

**In short.** Editing a setup retires every proof already given, even when the edited setup rewrites the identical rule.

**Property.** A proof issued under a setup never satisfies anything after that setup changes, including a change that restores the exact previous rule, across clearing and recommitting alike, since the nonce retires the request and the digest every conforming method verified against. No approval banked under an old setup ever comes back. Removing the kit's authorization alone is not a setup change and retires nothing, the dormant-setup boundary the design states.

**Rules out.** Banked-approval resurrection, configuration-cycle replay.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_aSetupWriteRetiresEveryProof`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheRequestWasSignedUnderARetiredSetup`

## I-13

**In short.** A proof past its window opens nothing.

**Property.** A request whose validity window has passed opens no attempt and cancels none. The policy manager checks the window before it reads any proof, so a stale request fails on the window rather than on a proof. The window is one field of the request, carried into the digest every verification receives, so a conforming method binds its verdict to it, while its width is the signing client's choice rather than a contract ceiling.

**Rules out.** Stale-proof acceptance.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_anExpiredRequestDoesNothing`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheWindowHasPassed`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheWindowHasPassedAndTheBodyDoesNotMatch`
- `test/policy-manager/PolicyManagerCancelByProofs.t.sol`: `test_WhenTheWindowHasPassed`

## I-14

**In short.** Methods are independent, one failing or hostile method never touches another.

**Property.** The policy manager calls every method through a static call and builds its arguments from that call's own digest, configuration and proof alone, so neither the method nor anything it calls writes any state during it and no method is handed another method's or another account's configuration, attempt or authority. A method holds no holder's configuration and no attempt of its own. What a method chooses to read is its own business and outside this guarantee, so a module that conditions its verdict on foreign state is a hostile module, contained the way any other is.

**Rules out.** Shared-failure coupling, cross-method state corruption, cross-account interference.

**Contracts.** `PolicyManager`, `EcdsaMethod`, `PasskeyMethod`, `AadhaarMethod`, `ZkPassportMethod`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_methodsRunIsolated`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenTheMethodWritesStateWhileVerifying`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenThePauseReadWritesState`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenACompleteSetIsAccepted`

## I-16

**In short.** The chain learns only what the holder chose to show.

**Property.** The only setup configuration in contract storage is the salted commitment, taken over the account, the action, the setup nonce and the setup body so no two accounts share one, revealing no method, clause structure, threshold, wait or pause choice whatever the holder's disclosure choice. An attempt additionally reveals the distinct methods its accepted set used, which the manager stores and the opening event carries, and which the record keeps after that attempt ends and after the setup is cleared, since the attempt record is overwritten rather than deleted. It reveals a credential only to a reader who can reproduce its preimage, so what hides one is the entropy of its configuration and its salt rather than anything the manager does, the manager taking the salt as a supplied value and hashing it. This kit's own SDK computes a default salt from the account and the place, which hides a wallet guardian only from a reader who cannot guess their address, and which a holder or another client replaces with any value, a client behaviour this invariant's fuzz cannot reach and the salt derivation's own vector pins, the one I-21 names. The setup nonce and the running attempt's state also live in that storage, the attempt keeping the outcome payload's hash, the payment order, the distinct methods its accepted set used and the pause choice it was judged under, from the moment its opening event published the cleartext, and reveal nothing of the rule beyond what that event already showed. Any reveal the holder opts into rides the setup event alone, the optional public metadata and the optional backup, encrypted or plain, private by default. Verification always runs against the commitment, never against revealed event data. A submitted request reveals the setup body it carries, the rule with its wait and its pause choice, together with the credentials it used and the action it names, whether or not it is accepted, all of it in the transaction's calldata, and an accepted opening publishes the body and the action in its own event besides.

**Rules out.** Setup leakage beyond the holder's choice, guessable commitments.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_storageHoldsOnlyTheCommitment`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenACompleteSetIsAccepted`

## I-17

**In short.** The lost key cannot take the account back after recovery.

**Property.** After a recovery completes, the replaced authority, which held power on the account when the handover executed, no longer holds it, removed by the committed action's batch in the account's own frame, on the chain the recovery ran on, and the action refuses a handover whose replaced authority holds no power, so a completed recovery never leaves the lost key in place. Authorities installed outside the handover's reach, a second validator, an extra owner, another module, a fallback handler, are not touched by it and are the holder's to enumerate at setup.

**Rules out.** Re-armed credential within the controlled authority, silent partial disarm.

**Contracts.** `PolicyManager`, `AmbireRecoveryAction`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/action/invariants/Invariants.t.sol`: `invariant_theLostKeyHoldsNoPowerOnceTheHandoverRuns`
- `test/action/invariants/Invariants.t.sol`: `invariant_aHandoverTouchesOnlyItsKeysAndItsPayment`
- `test/action/AmbireRecoveryActionValidateSig.t.sol`: `test_RevertWhen_TheRemovedKeyHoldsNoKeyValue`
- `test/action/AmbireRecoveryActionValidateSig.t.sol`: `test_RevertWhen_TheRemovedEntryIsTheKitSlot`
- `test/action/AmbireRecoveryActionExecuteHandover.t.sol`: `test_WhenTheLiveAccountRunsTheApprovedBatch`
- `test/action/AmbireRecoveryActionExecuteHandover.t.sol`: `test_RevertWhen_TheLiveRemovedKeyHoldsNoKeyValue`
- `test/integration/FallbackHandlerSurvivesRecovery.t.sol`: `test_WhenAHandlerOutlivesTheRecovery`
- `test/integration/FallbackHandlerSurvivesRecovery.t.sol`: `test_WhenTheNewKeyClearsTheHandlerFirst`

## I-18

**In short.** An approved handover executes at most once and exactly as committed, spent and applied as one atomic batch, nothing more.

**Property.** The policy manager releases an approved attempt at most once, through one spend only the account itself performs, after the wait, under the setup it was judged under, and for the committed attempt id and payload hash alone. The recovery action's own code builds one batch and only one, installing exactly the committed new authority at exactly the value that account's authority model reserves for a key, removing exactly the committed replaced one, carrying exactly the payment call the order named, and doing nothing else to the account. Whether that call moves value is the token's and the payee's business rather than the manager's, since the batch checks only that the call did not revert, and a payment that lands nowhere leaves the handover complete, the cost D-110 states. What narrows the batch is that code and its audit rather than the account's grant, which is unlimited once given, the boundary I-17 states. The account's authorization callback refuses every batch that is not that one, which narrows what this action will ask for and never what the account's grant allows. The spend rides that batch, so the whole handover lands or reverts as one unit, and the account never ends with no authority, since the action refuses a handover naming one address on both sides and refuses one naming no new authority at all. That nothing is spent without its writes rests on the action's code and audit rather than on a contract mechanism, since any contract the account authorized can send the spend alone.

**Rules out.** Action smuggling at release, half-executed rotation.

**Contracts.** `PolicyManager`, `AmbireRecoveryAction`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/action/invariants/Invariants.t.sol`: `invariant_theSpendRunsWithTheKeyWritesOrNotAtAll`
- `test/action/invariants/Invariants.t.sol`: `invariant_aSecondRunOfTheSameBatchRevertsWhole`
- `test/action/invariants/Invariants.t.sol`: `invariant_onlyTheApprovedBatchRuns`
- `test/action/invariants/Invariants.t.sol`: `invariant_everyOtherBatchIsRefusedByTheCheck`
- `test/action/invariants/Invariants.t.sol`: `invariant_theNewKeyHoldsExactlyTheKeyValue`
- `test/action/invariants/Invariants.t.sol`: `invariant_aHandoverTouchesOnlyItsKeysAndItsPayment`
- `test/action/invariants/Invariants.t.sol`: `invariant_theApprovedBatchRunsWhenItsConditionsHold`
- `test/action/AmbireRecoveryActionValidateSig.t.sol`: `test_RevertWhen_AThreeCallOrderGetsFourCalls`
- `test/action/AmbireRecoveryActionValidateSig.t.sol`: `test_RevertWhen_TheGrantWritesAValidatorBinding`
- `test/action/AmbireRecoveryActionValidateSig.t.sol`: `test_RevertWhen_TheCommittedKeysAreTheSameAddress`
- `test/action/AmbireRecoveryActionExecuteHandover.t.sol`: `test_WhenTheOrderPaysAToken`
- `test/action/AmbireRecoveryActionExecuteHandover.t.sol`: `test_WhenTheLiveTokenAnswersFalse`
- `test/action/AmbireRecoveryActionExecuteHandover.t.sol`: `test_WhenALivePayeeCallsTheAccountAgainWithTheSameBatch`
- `test/action/AmbireRecoveryActionExecuteHandover.t.sol`: `test_RevertWhen_TheLivePayeeRefusesThePayment`

## I-19

**In short.** A pause only refuses, it never lets a recovery through.

**Property.** The policy manager refuses the spend of an attempt whenever a method that attempt used answers the pause read with exactly true, and does not refuse it on any other answer, which is the manager declining to veto rather than a promise that the transaction completes. It refuses a proof from a method that answers the same read with exactly true at an opening and at a cancel by proofs. It makes every one of those reads only when the setup did not commit to ignore stops, a choice read from the revealed body and carried on the attempt from its acceptance, which no caller supplies. A conforming method reports its stop through that read and refuses nothing inside its own verification, so the manager is the only party that turns a stop into a refusal. No state of a pause makes the manager accept a request or spend an attempt the committed setup does not authorize, and neither pausing nor lifting re-judges, widens or replays anything the manager accepted before it. What a stop does grant is the one cancellation it authorizes, which ends an attempt rather than releasing one, and whose own conditions are D-111's rather than this invariant's. The manager and the action carry no pause at all.

**Rules out.** Pause as a bypass.

**Contracts.** `PolicyManager`, `AadhaarMethod`, `ZkPassportMethod`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_aStopOnlyRefuses`
- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_theSpendChecksItsOwnStorageFirst`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheFirstUsedMethodReportsAStop`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenEveryUsedMethodReportsAStop`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenThePauseReadRevertsWithTrue`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenThePauseReadReturnsTrueAndMore`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheAttemptIgnoresStops`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenAStopLiftsBeforeTheSpend`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenThePayloadFailsAndAUsedMethodReportsAStop`
- `test/policy-manager/PolicyManagerStartAttempt.t.sol`: `test_WhenAMethodReportsItselfStopped`

## I-49

**In short.** Only the current key admin re-keys an identity method, and only the current pause holder stops it.

**Property.** Each of the two identity methods, `method-aadhaar` and `method-zkpassport`, lets only its current key admin replace its trusted keys, offer the key admin role to another address or renounce that role, and lets only the address offered the key admin role take it, by accepting. Each lets only its current pause holder turn its stop on or off, offer the pause holder role or renounce it, and lets only the address offered that role take it, by accepting. Renouncing the key admin role clears any pending offer of that role first, so after it nobody takes the role and nobody changes the trusted keys. No call of the key admin moves the pause holder or the stop, and no call of the pause holder moves the key admin or the trusted keys.

**Rules out.** Unauthorized re-key forging every credential of the method, unauthorized stop blocking every recovery through it, role capture after renunciation.

**Contracts.** `AadhaarMethod`, `ZkPassportMethod`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/method-roles/PolicyMethodRolesFuzz.t.sol`: `testFuzz_onlyTheKeyAdminSetsKeys`
- `test/method-roles/PolicyMethodRolesFuzz.t.sol`: `testFuzz_onlyTheKeyAdminOffersTheRole`
- `test/method-roles/PolicyMethodRolesFuzz.t.sol`: `testFuzz_onlyTheNomineeAccepts`
- `test/method-roles/PolicyMethodRolesFuzz.t.sol`: `testFuzz_onlyTheKeyAdminRenounces`
- `test/method-roles/PolicyMethodRolesFuzz.t.sol`: `testFuzz_noNomineeAcceptsAfterRenounce`
- `test/method-roles/PolicyMethodRolesFuzz.t.sol`: `testFuzz_onlyThePauseHolderPauses`
- `test/method-roles/PolicyMethodRolesFuzz.t.sol`: `testFuzz_onlyThePauseHolderUnpauses`
- `test/method-roles/PolicyMethodRolesFuzz.t.sol`: `testFuzz_nobodyLiftsAStopAfterRenounce`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_onlyTheKeyAdminMovesTheKeys`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_onlyTheKeyAdminActsAsKeyAdmin`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_onlyTheOfferedAddressTakesTheKeyAdminRole`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_onlyThePauseHolderActsAsPauseHolder`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_onlyTheOfferedAddressTakesThePauseHolderRole`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_onlyThePauseHolderMovesTheStop`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_keyAdminCallsLeaveThePauseHolderRoleAlone`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_pauseHolderCallsLeaveTheKeyAdminRoleAlone`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_renouncedKeyAdminRoleStaysEmpty`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_renouncedWhilePausedStaysStopped`
- `test/method-roles/invariants/Invariants.t.sol`: `invariant_holdersAreNeverRefused`
- `test/method-zkpassport/ZkPassportMethodConstructor.t.sol`: `test_WhenEveryArgumentIsValid`
- `test/method-zkpassport/ZkPassportMethodDeclarations.t.sol`: `test_WhenTrustedPartiesAreRead`
- `test/method-aadhaar/AadhaarMethodConstructor.t.sol`: `test_WhenEveryArgumentIsValid`
- `test/method-aadhaar/AadhaarMethodDeclarations.t.sol`: `test_WhenTrustedPartiesAreRead`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenTheStoppedMethodIsTheLastUsedMethod`
- `test/integration/PauseStopsSuspectRecovery.t.sol`: `test_WhenTheStoppedMethodIsTheMiddleOfTheUsedMethods`
- `test/integration/IdentityMethodKeyRotation.t.sol`: `test_WhenTheKeyAdminForgesAProof`
- `test/integration/IdentityMethodKeyRotation.t.sol`: `test_WhenTheKeyAdminTriesToRouteProofsToARootVerifierItControls`
- `test/integration/IdentityMethodRoleHandover.t.sol`: `test_WhenTheKeyAdminHandsOnTheRole`
- `test/integration/IdentityMethodRoleHandover.t.sol`: `test_WhenThePauseHolderHandsOnTheRole`

## I-20

**In short.** Every setup write and every recovery step emits its event, no event lies.

**Property.** Every setup write and every attempt transition emits exactly one event naming it, no emitted event claims a transition that did not occur, so the event stream alone carries the whole state the policy manager holds. Whether the account still authorizes the contract is the account's own fact, read from the account beside that stream.

**Rules out.** Silent transition, phantom event, blinded watcher.

**Contracts.** `PolicyManager`.

**Checked by.** Fuzz and invariant tests, plus the unit tests that pin each edge.

**Tests**

- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_theEventStreamRebuildsTheState`
- `test/policy-manager/invariants/Invariants.t.sol`: `invariant_oneEventPerWriteAndTheCancelFirst`
- `test/policy-manager/PolicyManagerConsume.t.sol`: `test_WhenTheWaitIsOverAndNoUsedMethodVetoes`
- `test/policy-manager/PolicyManagerCancelByVeto.t.sol`: `test_WhenAUsedMethodReportsAStop`

## I-21

**In short.** The wallet app and the policy manager always build a shared message the same way, so the approval Ana signs on her phone is the approval the contract accepts.

**Property.** Every byte format the kit computes in more than one place yields identical bytes for the same inputs, always, whichever pair computes it, the SDK and the policy manager, the SDK and an action, or an action and the account, so a commitment, a digest or a binding one side produces always matches on the other. The shared formats are the binding digest with its own pre-hashed member, the credential commitment preimage, the setup commitment preimage, the attempt request and the cancellation request, the setup body encoding, each action's authorization slot and binding value, which the SDK and the action both compute, the manager's five event layouts and the method roles' six event layouts with the split between the fields each event indexes and writes into the data, which a contract emits and a client decodes, the account address a creation triple reproduces with the slots that creation code writes, which the account's own deployment produced and the SDK recomputes, and the recovered holder's typed-data wrapping, which the SDK and the account of the pinned revision both compute. Each action's outcome payload freezes as that action's own vector, the recovery handover among them. The SDK alone derives a credential's default salt, so the contracts do not expose that derivation and the contracts replay does not carry its vector.

**Rules out.** Cross-implementation encoding drift, a recovery that can never verify.

**Contracts.** `PolicyManager`, `AmbireRecoveryAction`, `AadhaarMethod`, `ZkPassportMethod`.

**Checked by.** Known-answer vectors under `test/fixtures/kats/`, replayed by the tests below.

**Tests**

- `test/kat/BindingDigestKat.t.sol`: `test_WhenReplayingTheApprovalDigestVectors`
- `test/kat/BindingDigestKat.t.sol`: `test_WhenReplayingTheCancellationDigestVectors`
- `test/kat/BindingDigestKat.t.sol`: `test_WhenReplayingTheSetupCommitmentVectors`
- `test/kat/BindingDigestKat.t.sol`: `test_WhenReplayingTheCredentialCommitmentVectors`
- `test/kat/PolicyManagerDigestKat.t.sol`: `test_WhenReplayingTheApprovalDigestVectorsThroughTheManager`
- `test/kat/PolicyManagerDigestKat.t.sol`: `test_WhenReplayingTheCancellationDigestVectorsThroughTheManager`
- `test/kat/PolicyManagerCommitmentKat.t.sol`: `test_WhenEncodingTheCredentialCommitmentPreimages`
- `test/kat/PolicyManagerCommitmentKat.t.sol`: `test_WhenEncodingTheSetupCommitmentPreimages`
- `test/kat/PolicyManagerCommitmentKat.t.sol`: `test_WhenCommittingARowTheManagerRefuses`
- `test/kat/PolicyManagerRequestKat.t.sol`: `test_WhenEncodingThePaymentOrderVectors`
- `test/kat/PolicyManagerRequestKat.t.sol`: `test_WhenEncodingTheProofPlaceVectors`
- `test/kat/PolicyManagerRequestKat.t.sol`: `test_WhenEncodingTheAttemptRequestVectors`
- `test/kat/PolicyManagerRequestKat.t.sol`: `test_WhenEncodingTheCancelRequestVectors`
- `test/kat/PolicyManagerRequestKat.t.sol`: `test_WhenTheManagerReadsTheAttemptRequestVectors`
- `test/kat/PolicyManagerRequestKat.t.sol`: `test_WhenTheManagerReadsTheCancelRequestVectors`
- `test/kat/SetupBodyKat.t.sol`: `test_WhenReadingBackEveryVectorsEncoding`
- `test/kat/SetupBodyKat.t.sol`: `test_WhenDecodingEveryVectorsEncoding`
- `test/kat/SetupBodyKat.t.sol`: `test_WhenTheLibraryEncoderEncodesEveryVectorsInput`
- `test/kat/AmbireRecoveryActionKat.t.sol`: `test_WhenReplayingTheKitSlotVectorsThroughTheAction`
- `test/kat/AmbireKitSlotKat.t.sol`: `test_WhenReplayingTheKitSlotPreimagesThroughTheAction`
- `test/kat/AmbireHandoverKat.t.sol`: `test_WhenReplayingTheHandoverRowsTheActionAccepts`
- `test/kat/AmbireHandoverKat.t.sol`: `test_WhenReplayingTheHandoverRowsTheActionRefuses`
- `test/kat/AmbireHandoverKat.t.sol`: `test_WhenOpeningTheOpaqueHandoverRowsThroughTheManager`
- `test/kat/PolicyManagerEventsKat.t.sol`: `test_WhenTheAccountCommitsTheSetupCommittedRow`
- `test/kat/PolicyManagerEventsKat.t.sol`: `test_WhenTheAccountClearsTheSetupClearedRow`
- `test/kat/PolicyManagerEventsKat.t.sol`: `test_WhenTheManagerEmitsTheAttemptStartedRow`
- `test/kat/PolicyManagerEventsKat.t.sol`: `test_WhenTheCancellerVetoesTheAttemptCancelledRow`
- `test/kat/PolicyManagerEventsKat.t.sol`: `test_WhenTheAccountConsumesTheAttemptConsumedRow`
- `test/kat/PolicyMethodRolesEventsKat.t.sol`: `test_WhenThePauseHolderPausesThePausedRow`
- `test/kat/PolicyMethodRolesEventsKat.t.sol`: `test_WhenThePauseHolderUnpausesTheUnpausedRow`
- `test/kat/PolicyMethodRolesEventsKat.t.sol`: `test_WhenTheKeyAdminSetsTheTrustedKeysUpdatedRow`
- `test/kat/PolicyMethodRolesEventsKat.t.sol`: `test_WhenTheKeyAdminOffersTheAdminTransferOfferedRow`
- `test/kat/PolicyMethodRolesEventsKat.t.sol`: `test_WhenTheNomineeAcceptsTheAdminTransferredRow`
- `test/kat/PolicyMethodRolesEventsKat.t.sol`: `test_WhenTheKeyAdminRenouncesTheAdminRenouncedRow`
- `test/kat/PolicyMethodRolesEventsKat.t.sol`: `test_WhenCountingTheMethodEventRows`

## I-22

**In short.** The approval a helper's app produces is exactly the approval the method module expects, so a yes gathered off chain never turns into a rejection on chain.

**Property.** Every proof format yields identical bytes in every implementation that computes it, always, the verdict's magic value among them, since every method author reproduces that constant and a wrong one rejects every proof. The SDK that gathers a proof and the method module that verifies it agree on each method's own config layout, which the SDK writes at setup and the module reads at every verification, on the typed message a wallet signature covers, on the passkey assertion's layout and check list, and on how each identity proof takes the digest as a public input, the identity formats joining as their methods ship, so a proof gathered off chain verifies on chain under the same request and the same verifier state. What a verifier accepts can change between the gathering and the submission, which the design records as a provider failure, and no vector certifies against that.

**Rules out.** Cross-implementation encoding drift, a gathered proof the chain rejects.

**Contracts.** `EcdsaMethod`, `PasskeyMethod`, `AadhaarMethod`, `ZkPassportMethod`.

**Checked by.** Known-answer vectors under `test/fixtures/kats/`, replayed by the tests below.

**Tests**

- `test/kat/MethodVerdictKat.t.sol`: `test_WhenReplayingTheVerdictVectorAgainstTheInterface`
- `test/kat/MethodVerdictKat.t.sol`: `test_WhenReplayingTheVerdictVectorAgainstAcceptedProofs`
- `test/kat/MethodVerdictKat.t.sol`: `test_WhenReplayingTheVerdictVectorAgainstRefusedProofs`
- `test/kat/EcdsaMethodKat.t.sol`: `test_WhenReplayingTheConfigVectors`
- `test/kat/EcdsaMethodKat.t.sol`: `test_WhenReplayingTheZeroSignerConfigVector`
- `test/kat/EcdsaMethodKat.t.sol`: `test_WhenReplayingTheProofVectors`
- `test/kat/EcdsaMethodKat.t.sol`: `test_WhenReplayingTheAcceptedProofVectorsWrapped`
- `test/kat/PasskeyMethodKat.t.sol`: `test_WhenReplayingTheConfigVectors`
- `test/kat/PasskeyMethodKat.t.sol`: `test_WhenReplayingTheConfigVectorThroughTheMethod`
- `test/kat/PasskeyMethodKat.t.sol`: `test_WhenReplayingTheProofEncodingVectors`
- `test/kat/PasskeyMethodKat.t.sol`: `test_WhenReplayingTheProofChallengeVectors`
- `test/kat/PasskeyMethodKat.t.sol`: `test_WhenReplayingTheProofSignedHashVectors`
- `test/kat/PasskeyMethodKat.t.sol`: `test_WhenReplayingTheProofSignatureVectors`
- `test/kat/PasskeyMethodKat.t.sol`: `test_WhenReplayingTheProofVerdictVectors`
- `test/kat/AadhaarMethodKat.t.sol`: `test_WhenReplayingTheConfigVectorsAgainstMatchingInputs`
- `test/kat/AadhaarMethodKat.t.sol`: `test_WhenReplayingTheConfigVectorsAgainstSwappedInputs`
- `test/kat/AadhaarMethodKat.t.sol`: `test_WhenReplayingTheProofVectors`
- `test/kat/AadhaarMethodKat.t.sol`: `test_WhenReplayingTheProofVectorsForAnotherDigest`
- `test/kat/AadhaarMethodKat.t.sol`: `test_WhenReplayingTheVectorsThroughTheTestBuilders`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheConfigVectorEncodings`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheConfigVectorsThroughVerify`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheConfigVectorsWithAnotherReturnedIdentifier`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorEncodings`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorRenderings`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorsThroughVerify`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorsWithUppercaseCustomData`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorsWithUnprefixedCustomData`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorsWithTheNullifierInputChanged`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorsWithAnotherInputChanged`
- `test/kat/ZkPassportMethodKat.t.sol`: `test_WhenReplayingTheProofVectorsUnderAnotherDigest`
