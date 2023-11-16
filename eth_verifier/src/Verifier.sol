// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.4.16 <0.9.0;

import "../lib/Fields.sol";
import "../lib/BN254.sol";
import "../lib/VerifierIndex.sol";
import "../lib/Commitment.sol";
import "../lib/Oracles.sol";
import "../lib/Proof.sol";
import "../lib/State.sol";
import "../lib/VerifierIndex.sol";
import "../lib/Commitment.sol";
import "../lib/msgpack/Deserialize.sol";

using {BN254.neg} for BN254.G1Point;
using {Scalar.neg} for Scalar.FE;

library Kimchi {
    struct Proof {
        uint256 data;
    }

    struct ProofInput {
        uint256[] serializedProof;
    }

    struct ProverProof {
        // evals

        // opening proof
        BN254.G1Point opening_proof_quotient;
        uint256 opening_proof_blinding;
    }

    struct Evals {
        Base.FE zeta;
        Base.FE zeta_omega;
    }

    /*
    function deserializeEvals(
        uint8[71] calldata serialized_evals
    ) public view returns (Evals memory evals) {}
    */
}

contract KimchiVerifier {
    VerifierIndex verifier_index;
    ProverProof proof;

    State internal state;
    bool state_available;

    function setup(
        BN254.G1Point[] memory g,
        BN254.G1Point memory h,
        uint256 public_len,
        uint256 domain_size,
        uint256 max_poly_size,
        ProofEvaluations memory evals
    ) public {
        for (uint i = 0; i < g.length; i++) {
            verifier_index.urs.g.push(g[i]);
        }
        verifier_index.urs.h = h;
        calculate_lagrange_bases(
            g,
            h,
            domain_size,
            verifier_index.urs.lagrange_bases_unshifted
        );
        verifier_index.public_len = public_len;
        verifier_index.domain_size = domain_size;
        verifier_index.max_poly_size = max_poly_size;

        proof.evals = evals;
    }

    function verify_state(
        bytes calldata state_serialized,
        bytes calldata proof_serialized
    ) public returns (bool) {
        // 1. Deserialize proof and setup

        // For now, proof consists in the concatenation of the bytes that
        // represent the numerator, quotient and divisor polynomial
        // commitments (G1 and G2 points).

        // BEWARE: quotient must be negated.

        (
            BN254.G1Point memory numerator,
            BN254.G1Point memory quotient,
            BN254.G2Point memory divisor
        ) = MsgPk.deserializeFinalCommitments(proof_serialized);

        bool success = BN254.pairingProd2(
            numerator,
            BN254.P2(),
            quotient,
            divisor
        );

        // 3. If success, deserialize and store state
        if (success) {
            store_state(state_serialized);
            state_available = true;
        }

        return success;
    }

    error IncorrectPublicInputLength();

    function partial_verify(Scalar.FE[] memory public_inputs) public {
        uint256 chunk_size = verifier_index.domain_size <
            verifier_index.max_poly_size
            ? 1
            : verifier_index.domain_size / verifier_index.max_poly_size;

        if (public_inputs.length != verifier_index.public_len) {
            revert IncorrectPublicInputLength();
        }
        PolyCommFlat memory lgr_comm_flat = verifier_index
            .urs
            .lagrange_bases_unshifted[verifier_index.domain_size];
        PolyComm[] memory comm = new PolyComm[](verifier_index.public_len);
        PolyComm[] memory lgr_comm = poly_comm_unflat(lgr_comm_flat);
        // INFO: can use unchecked on for loops to save gas
        for (uint256 i = 0; i < verifier_index.public_len; i++) {
            comm[i] = lgr_comm[i];
        }
        PolyComm memory public_comm;
        if (public_inputs.length == 0) {
            BN254.G1Point[] memory blindings = new BN254.G1Point[](chunk_size);
            for (uint256 i = 0; i < chunk_size; i++) {
                blindings[i] = verifier_index.urs.h;
            }
            public_comm = PolyComm(blindings);
        } else {
            Scalar.FE[] memory elm = new Scalar.FE[](public_inputs.length);
            for (uint i = 0; i < elm.length; i++) {
                elm[i] = public_inputs[i].neg();
            }
            PolyComm memory public_comm_tmp = polycomm_msm(comm, elm);
            Scalar.FE[] memory blinders = new Scalar.FE[](
                public_comm_tmp.unshifted.length
            );
            for (uint i = 0; i < public_comm_tmp.unshifted.length; i++) {
                blinders[i] = Scalar.FE.wrap(1);
            }
            public_comm = mask_custom(
                verifier_index.urs,
                public_comm_tmp,
                blinders
            ).commitment;
        }

        Oracles.fiat_shamir(verifier_index);
    }

    /*
    This is a list of steps needed for verification, we need to determine which
    ones can be skipped or simplified.

    Partial verification:
        1. Check the length of evaluations insde the proof.
        2. Commit to the negated public input poly
        3. Fiat-Shamir (MAY SKIP OR VASTLY SIMPLIFY)
        4. Combined chunk polynomials evaluations
        5. Commitment to linearized polynomial f
        6. Chunked commitment of ft
        7. List poly commitments for final verification

    Final verification:
        1. Combine commitments, compute final poly commitment (MSM)
        2. Combine evals
        3. Commit divisor and eval polynomials
        4. Compute numerator commitment
        5. Compute scaled quotient
        6. Check numerator == scaled_quotient
    */

    /* TODO WIP
    function deserialize_proof(
        uint256[] calldata public_inputs,
        uint256[] calldata serialized_proof
    ) returns (Proof memory) {}
    */

    /// @notice This is used exclusively in `test_PartialVerify()`.
    function set_verifier_index_for_testing() public {
        verifier_index.max_poly_size = 1;
    }

    /// @notice store a mina state
    function store_state(bytes memory data) internal {
        state = MsgPk.deserializeState(data, 0);
    }

    /// @notice check if state is available
    function is_state_available() public view returns (bool) {
        return state_available;
    }

    error UnavailableState();

    /// @notice retrieves the base58 encoded creator's public key
    function retrieve_state_creator() public view returns (string memory) {
        if (!state_available) {
            revert UnavailableState();
        }
        return state.creator;
    }

    /// @notice retrieves the hash of the state after this block
    function retrieve_state_hash() public view returns (uint) {
        if (!state_available) {
            revert UnavailableState();
        }
        return state.hash;
    }

    /// @notice retrieves the block height
    function retrieve_state_height() public view returns (uint) {
        if (!state_available) {
            revert UnavailableState();
        }
        return state.block_height;
    }
}