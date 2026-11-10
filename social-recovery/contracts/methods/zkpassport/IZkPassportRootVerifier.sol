// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IZkPassportVerifierHelper} from 'contracts/methods/zkpassport/IZkPassportVerifierHelper.sol';

/// @title IZkPassportRootVerifier
/// @author defi-wonderland
/// @notice The one call this method makes on zkPassport's root verifier, the router that resolves the
///         sub-verifier and the verifier helper for a version.
interface IZkPassportRootVerifier {
  /*///////////////////////////////////////////////////////////////
                              STRUCTS
  ///////////////////////////////////////////////////////////////*/

  /// @notice The proof zkPassport's prover produces, in the field order the upstream root verifier reads.
  /// @param vkeyHash The hash of the verification key of the outer circuit that produces the proof.
  /// @param proof The proof bytes.
  /// @param publicInputs The proof's public inputs. The nullifier type sits third from the end.
  struct ProofVerificationData {
    bytes32 vkeyHash;
    bytes proof;
    bytes32[] publicInputs;
  }

  /// @notice The service a zkPassport proof is requested for, in the field order the upstream root verifier reads.
  /// @param validityPeriodInSeconds How long after its generation the proof stays acceptable.
  /// @param domain The service domain the proof is scoped to.
  /// @param scope The service scope the proof is scoped to.
  /// @param devMode Whether the root verifier accepts development proofs. This method always passes false.
  struct ServiceConfig {
    uint256 validityPeriodInSeconds;
    string domain;
    string scope;
    bool devMode;
  }

  /// @notice Everything the upstream root verifier's `verify` takes, in its field order.
  /// @param version The zkPassport version whose proof route the root verifier selects.
  /// @param proofVerificationData The proof and its public inputs.
  /// @param committedInputs The preimages of the proof's parameter commitments.
  /// @param serviceConfig The service the proof must be scoped to.
  struct ProofVerificationParams {
    bytes32 version;
    ProofVerificationData proofVerificationData;
    bytes committedInputs;
    ServiceConfig serviceConfig;
  }

  /*///////////////////////////////////////////////////////////////
                              LOGIC
  ///////////////////////////////////////////////////////////////*/

  /// @notice Verifies a zkPassport proof through the sub-verifier registered for the version it names.
  /// @param params The version, the proof, its committed inputs and the service configuration.
  /// @return valid True when the sub-verifier accepts the proof.
  /// @return uniqueIdentifier The identifier the proof derives for the identity document it comes from.
  /// @return helper The verifier helper registered for the version, which reads the proof's committed inputs.
  function verify(ProofVerificationParams calldata params)
    external
    view
    returns (bool valid, bytes32 uniqueIdentifier, IZkPassportVerifierHelper helper);
}
