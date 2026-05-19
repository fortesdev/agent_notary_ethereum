// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { IEAS, AttestationRequest, AttestationRequestData } from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IFeeRegistry.sol";

/**
 * @title NotaryCore
 * @notice Agent Notary — asymmetric interaction witnessing for AI agents.
 *
 * ── STATE MACHINE (REFINED) ──────────────────────────────────────────────────
 *
 *   STATE_PENDING        (0)  Submitter opened slot; waiting for confirmer.
 *   STATE_WITNESSED      (1)  Both parties submitted matching ACCEPTED hashes.
 *                             → Success Badge issued.
 *   STATE_FAILED         (2)  Confirmer rejected the interaction.
 *                             → Failure Badge issued to SUBMITTER.
 *   STATE_DISPUTED       (3)  Confirmer accepted, but Submitter rejected or
 *                             hash mismatch despite both accepting.
 *                             → No badge. On-chain record only.
 *   STATE_DECLINED       (4)  Confirmer sent CANCEL or Submitter initially
 *                             sent FAILURE (treated as cancellation).
 *                             → No badge. Deposits refunded.
 *   STATE_EXPIRED        (5)  Timeout elapsed with no confirmer response.
 *                             → No badge. Submitter deposit refunded.
 *
 * ── OUTCOME SIGNALS ──────────────────────────────────────────────────────────
 *
 *   ACCEPTED  (1)  "This interaction completed as described."
 *   CANCELLED (2)  "I decline to participate/complete this."
 *   FAILURE   (3)  "This interaction was malicious or failed."
 *
 * ── ASYMMETRIC LOGIC ─────────────────────────────────────────────────────────
 *
 *   1. Confirmer Authority: If the Confirmer marks FAILURE, the Submitter is
 *      penalized with a Failure Badge immediately. The Submitter's input is
 *      overruled as the Confirmer is the service-providing authority.
 *
 *   2. Submitter Protection: If the Confirmer claims SUCCESS but the Submitter
 *      claims FAILURE/Mismatch, the state is DISPUTED. This prevents malicious
 *      Submitters from instantly ruining a Confirmer's reputation, while
 *      still flagging the conflict.
 *
 *   3. Submitter Error: If the Submitter starts a slot with FAILURE, it is
 *      treated as a CANCEL/DECLINED state (refunded) as it makes no sense
 *      to invest to report oneself as failed before a response is even possible.
 *
 *   4. Dynamic Investment (Proof-of-Stake): Each party decides how much USDC
 *      to invest in the interaction. These amounts are reflected in the badge.
 *
 * ── RIGGING ANALYSIS (UPDATED) ───────────────────────────────────────────────
 *
 *   - Confirmer ignores → EXPIRED. No badge for either party. Submitter refunded.
 *   - Confirmer cancels → DECLINED. Both parties' deposits refunded.
 *   - Hash includes both addresses: neither party can pre-compute a match
 *     without knowing the counterparty's address.
 *   - Per-address nonce prevents replay.
 *   - Investments deducted before EAS write (checks-effects-interactions pattern).
 */
contract NotaryCore is Ownable {

    // ── Mutable State ───────────────────────────────────────────────────────
    IEAS         public eas;
    IFeeRegistry public feeRegistry;
    bytes32      public witnessedSchemaUID;
    bytes32      public failureSchemaUID;

    // ── Outcome constants ───────────────────────────────────────────────────
    uint8 public constant OUTCOME_ACCEPTED  = 1;
    uint8 public constant OUTCOME_CANCELLED = 2;
    uint8 public constant OUTCOME_FAILURE   = 3;

    // ── Slot states ─────────────────────────────────────────────────────────
    uint8 public constant STATE_PENDING        = 0;
    uint8 public constant STATE_WITNESSED      = 1;
    uint8 public constant STATE_FAILED         = 2;
    uint8 public constant STATE_DISPUTED       = 3;
    uint8 public constant STATE_DECLINED       = 4;
    uint8 public constant STATE_EXPIRED        = 5;

    // ── Slot storage ────────────────────────────────────────────────────────
    struct Slot {
        bytes32 submitterHash;       // hash submitted by first party
        uint8   submitterOutcome;    // outcome is now inside the hash too (FIX #6)
        address submitter;
        address confirmer;
        uint64  expiresAt;
        uint8   state;
        bool    confirmerDone;
        uint256 submitterDeposit;    // amount invested by submitter
        uint256 confirmerDeposit;    // amount invested by confirmer
        // Stored so confirmHash can verify the confirmer uses the same nonce (FIX #9)
        bytes32 sharedNonce;
    }

    // interactionId => Slot
    mapping(bytes32 => Slot) public slots;

    // ── Events ──────────────────────────────────────────────────────────────
    event HashSubmitted(
        bytes32 indexed interactionId,
        address indexed party,
        uint8 outcome
    );
    event WitnessedAttestation(
        bytes32 indexed interactionId,
        address indexed submitter,
        address indexed confirmer,
        bytes32 outcomeHash,
        uint256 amountBurned,
        uint16 score,
        bytes32 easUID
    );
    event FailureAttestation(
        bytes32 indexed interactionId,
        address indexed failingParty,
        address indexed otherParty,
        uint256 amountBurned,
        uint16 score,
        bytes32 easUID
    );
    // Both parties' hashes and outcomes are included so the full conflict is
    // self-contained in the event log — no off-chain data required to audit.
    event Disputed(
        bytes32 indexed interactionId,
        address submitter,
        address confirmer,
        bytes32 submitterHash,
        uint8   submitterOutcome,
        bytes32 confirmerHash,
        uint8   confirmerOutcome
    );
    event Declined(bytes32 indexed interactionId, address indexed actor);
    event Expired(bytes32 indexed interactionId);

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor(
        address _eas,
        address _feeRegistry,
        bytes32 _witnessedSchemaUID,
        bytes32 _failureSchemaUID,
        address _initialOwner
    ) {
        eas                = IEAS(_eas);
        feeRegistry        = IFeeRegistry(_feeRegistry);
        witnessedSchemaUID = _witnessedSchemaUID;
        failureSchemaUID   = _failureSchemaUID;
        _transferOwnership(_initialOwner);
    }

    // ── Setters ─────────────────────────────────────────────────────────────

    function setEAS(address _eas) external onlyOwner {
        eas = IEAS(_eas);
    }

    function setFeeRegistry(address _feeRegistry) external onlyOwner {
        feeRegistry = IFeeRegistry(_feeRegistry);
    }

    function setWitnessedSchemaUID(bytes32 _uid) external onlyOwner {
        witnessedSchemaUID = _uid;
    }

    function setFailureSchemaUID(bytes32 _uid) external onlyOwner {
        failureSchemaUID = _uid;
    }

    // ── Hash computation ────────────────────────────────────────────────────

    /**
     * @notice Compute the outcome match hash. Call this off-chain before submitting.     *
     * @param interactionId  Shared UUID agreed off-chain (bytes32).
     * @param outcomeData    ABI-encoded outcome payload (must include high-entropy salt).
     * @param timestamp      Unix timestamp agreed by both parties.
     * @param addrA          One party's address.
     * @param addrB          The other party's address.
     * @param outcome        Outcome byte (1=ACCEPTED, 2=CANCELLED, 3=FAILURE).
     * @param sharedNonce    Single shared nonce for anti-replay.
     */
    function computeHash(
        bytes32 interactionId,
        bytes memory outcomeData,
        uint64 timestamp,
        address addrA,
        address addrB,
        uint8 outcome,
        bytes32 sharedNonce
    ) public pure returns (bytes32) {
        (address first, address second) = addrA < addrB
            ? (addrA, addrB)
            : (addrB, addrA);

        return keccak256(abi.encode(
            interactionId,
            outcomeData,
            timestamp,
            first,
            second,
            outcome,
            sharedNonce
        ));
    }

    // ── Submitter Logic ─────────────────────────────────────────────────────

    /**
     * @notice Open a new interaction slot.
     * @param interactionId     Shared UUID agreed off-chain.
     * @param outcomeHash       Result of computeHash() — commits to outcome + data.
     * @param outcome           Outcome signal (1/2/3).
     * @param counterparty      The confirmer's address.
     * @param expirationHours   Hours until the slot expires.
     * @param sharedNonce       Anti-replay nonce.
     * @param depositAmount     Amount invested from agent credit (Proof-of-Stake).
     */
    function submitHash(
        bytes32 interactionId,
        bytes32 outcomeHash,
        uint8   outcome,
        address counterparty,
        uint32  expirationHours,
        bytes32 sharedNonce,
        uint256 depositAmount
    ) external {
        require(outcome >= 1 && outcome <= 3,     "NotaryCore: invalid outcome");
        require(counterparty != address(0),        "NotaryCore: zero counterparty");
        require(counterparty != msg.sender,        "NotaryCore: self-attestation");
        require(expirationHours > 0,               "NotaryCore: expiration required");

        Slot storage slot = slots[interactionId];
        require(slot.submitter == address(0),      "NotaryCore: slot already exists");

        // Deduct amount from agent balance BEFORE writing state (CEI pattern)
        feeRegistry.collectCustomFee(msg.sender, depositAmount);

        // If Submitter starts with FAILURE, we treat it as an immediate DECLINED (refunded).
        if (outcome == OUTCOME_FAILURE) {
            slot.state = STATE_DECLINED;
            slot.submitter = msg.sender;
            _refundFee(msg.sender, depositAmount);
            emit Declined(interactionId, msg.sender);
            return;
        }

        slot.submitter        = msg.sender;
        slot.confirmer        = counterparty;
        slot.submitterHash    = outcomeHash;
        slot.submitterOutcome = outcome;
        slot.expiresAt        = uint64(block.timestamp) + uint64(expirationHours) * 3600;
        slot.state            = STATE_PENDING;
        slot.submitterDeposit = depositAmount;
        slot.sharedNonce      = sharedNonce;

        emit HashSubmitted(interactionId, msg.sender, outcome);
    }

    // ── Confirmer Logic ─────────────────────────────────────────────────────

    /**
     * @notice Respond to an open interaction slot.
     * @param interactionId  Must match an existing PENDING slot.
     * @param outcomeHash    Confirmer's hash.
     * @param outcome        Confirmer's outcome signal.
     * @param counterparty   Must equal slot.submitter.
     * @param sharedNonce    Must equal slot.sharedNonce.
     * @param depositAmount  Amount invested from agent credit (Proof-of-Stake).
     */
    function confirmHash(
        bytes32 interactionId,
        bytes32 outcomeHash,
        uint8   outcome,
        address counterparty,
        bytes32 sharedNonce,
        uint256 depositAmount
    ) external {
        require(outcome >= 1 && outcome <= 3, "NotaryCore: invalid outcome");

        Slot storage slot = slots[interactionId];
        require(slot.state == STATE_PENDING,   "NotaryCore: already resolved");
        require(block.timestamp <= slot.expiresAt, "NotaryCore: slot expired");
        require(msg.sender == slot.confirmer,  "NotaryCore: wrong confirmer");
        require(!slot.confirmerDone,           "NotaryCore: already submitted");

        require(counterparty == slot.submitter, "NotaryCore: counterparty mismatch");

        require(sharedNonce == slot.sharedNonce, "NotaryCore: nonce mismatch");

        slot.confirmerDone = true;
        slot.confirmerDeposit = depositAmount;

        // Deduct amount from agent balance BEFORE writing state (CEI pattern)
        feeRegistry.collectCustomFee(msg.sender, depositAmount);

        // 1. Confirmer Cancels
        if (outcome == OUTCOME_CANCELLED) {
            slot.state = STATE_DECLINED;
            // Refund both parties their dynamic deposits
            _refundFee(slot.submitter, slot.submitterDeposit);
            _refundFee(msg.sender, slot.confirmerDeposit);
            emit Declined(interactionId, msg.sender);
            return;
        }

        // 2. Confirmer Authority: FAILURE penalizes Submitter
        if (outcome == OUTCOME_FAILURE) {
            slot.state = STATE_FAILED;
            
            uint256 totalFee = slot.submitterDeposit + slot.confirmerDeposit;
            uint256 burned = feeRegistry.settleFees(totalFee);

            bytes32 uid = _writeFailureAttestation(
                interactionId,
                slot.submitter,
                msg.sender,
                burned,
                0 // Score 0 for failure
            );
            emit FailureAttestation(interactionId, slot.submitter, msg.sender, burned, 0, uid);
            return;
        }

        // 3. Confirmer Accept Path
        if (slot.submitterOutcome == OUTCOME_ACCEPTED && slot.submitterHash == outcomeHash) {
            // Success
            slot.state = STATE_WITNESSED;

            uint256 totalFee = slot.submitterDeposit + slot.confirmerDeposit;
            uint256 burned = feeRegistry.settleFees(totalFee);

            bytes32 uid = _writeWitnessedAttestation(
                interactionId,
                slot.submitter,
                msg.sender,
                outcomeHash,
                burned,
                1000 // Score 1000 for success
            );
            emit WitnessedAttestation(interactionId, slot.submitter, msg.sender, outcomeHash, burned, 1000, uid);
        } else {
            // Dispute: submitter claimed something else or hashes mismatched.
            slot.state = STATE_DISPUTED;
            
            uint256 totalFee = slot.submitterDeposit + slot.confirmerDeposit;
            feeRegistry.settleFees(totalFee);

            emit Disputed(
                interactionId,
                slot.submitter,
                msg.sender,
                slot.submitterHash,
                slot.submitterOutcome,
                outcomeHash,
                outcome
            );
        }
    }

    // ── Expiry ──────────────────────────────────────────────────────────────

    /// @notice Mark an expired slot. Callable by anyone after timeout.
    function markExpired(bytes32 interactionId) external {
        Slot storage slot = slots[interactionId];
        require(slot.submitter != address(0), "NotaryCore: no submission");
        require(slot.state == STATE_PENDING,  "NotaryCore: already resolved");
        require(block.timestamp > slot.expiresAt, "NotaryCore: not yet expired");
        slot.state = STATE_EXPIRED;
        _refundFee(slot.submitter, slot.submitterDeposit);
        emit Expired(interactionId);
    }

    // ── Internal Helpers ────────────────────────────────────────────────────

    function _writeWitnessedAttestation(
        bytes32 interactionId,
        address submitter,
        address confirmer,
        bytes32 outcomeHash,
        uint256 amountBurned,
        uint16 score
    ) internal returns (bytes32) {
        bytes memory data = abi.encode(
            interactionId,
            submitter,
            confirmer,
            outcomeHash,
            amountBurned,
            score,
            uint64(block.timestamp),
            block.chainid
        );
        return eas.attest(AttestationRequest({
            schema: witnessedSchemaUID,
            data: AttestationRequestData({
                recipient: address(0),
                expirationTime: 0,
                revocable: false,
                refUID: bytes32(0),
                data: data,
                value: 0
            })
        }));
    }

    function _writeFailureAttestation(
        bytes32 interactionId,
        address failingParty,
        address otherParty,
        uint256 amountBurned,
        uint16 score
    ) internal returns (bytes32) {
        bytes memory data = abi.encode(
            interactionId,
            failingParty,
            otherParty,
            amountBurned,
            score,
            uint64(block.timestamp),
            block.chainid
        );
        return eas.attest(AttestationRequest({
            schema: failureSchemaUID,
            data: AttestationRequestData({
                recipient: failingParty,
                expirationTime: 0,
                revocable: false,
                refUID: bytes32(0),
                data: data,
                value: 0
            })
        }));
    }



    function _refundFee(address agent, uint256 amount) internal {
        feeRegistry.refundFee(agent, amount);
    }
}
