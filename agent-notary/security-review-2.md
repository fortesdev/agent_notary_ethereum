# Security & Architectural Review (v2.0) - Agent Notary

**Date:** March 7, 2026  
**Status:** CRITICAL ISSUES IDENTIFIED  
**Scope:** `NotaryCore.sol`, `FeeRegistry.sol`, `AgentNotary.ts`, `a2a-messages.ts`

---

## 1. Smart Contract Findings (Solidity)

### [CRITICAL] Missing Fee Refund Logic
*   **Location:** `NotaryCore.sol`, `FeeRegistry.sol`
*   **Description:** The documentation (NatSpec) states that in `STATE_DECLINED` or `STATE_EXPIRED`, the submitter's fee is refunded. However, the implementation of `_collectFee` in `FeeRegistry` is irreversible. There is no `refundFee` or `creditBalance` function to return USDC to the agent.
*   **Impact:** Submitting agents lose funds whenever a counterparty is unresponsive or declines, creating a griefing vector where an attacker can drain an agent's balance by ignoring their requests.
*   **Recommendation:** Implement a `refundFee(address agent, uint256 amount)` function in `FeeRegistry` accessible only by `NotaryCore`.

### [LOW] Unused Parameter in `submitHash`
*   **Location:** `NotaryCore.sol` -> `submitHash(..., bytes32 sharedNonce)`
*   **Description:** The `sharedNonce` is passed to the function but never stored in the `Slot` struct or used in any logic.
*   **Impact:** Unnecessary gas consumption (approx. 2,100 gas for the extra calldata word).
*   **Recommendation:** Remove the parameter if the commitment is already handled via the `outcomeHash`.

---

## 2. SDK & Protocol Findings (TypeScript/A2A)

### [MAJOR] Non-Deterministic Hash Generation
*   **Location:** `AgentNotary.ts` -> `computeOutcomeHash`
*   **Description:** The SDK uses `JSON.stringify(outcomeData)` to prepare the payload for hashing. JavaScript engines do not guarantee property order in `JSON.stringify`.
*   **Scenario:** Agent A (Node.js) produces `{"status":"ok","salt":"123"}` while Agent B (Python/Rust) produces `{"salt":"123","status":"ok"}`.
*   **Impact:** Hashes will mismatch on-chain, leading to `STATE_DISPUTED` and loss of fees for both parties despite a successful interaction.
*   **Recommendation:** Use a deterministic JSON library (e.g., `json-stable-stringify`) or ABI-encode the `outcomeData` if the schema is known.

### [MAJOR] "Lost Salt" Bug in `submitHash`
*   **Location:** `AgentNotary.ts` -> `submitHash`
*   **Description:** If `outcomeData` does not contain a salt, the SDK generates one internally but **does not return it** to the caller.
*   **Impact:** The submitter cannot share the generated salt with the confirmer via the `NotaryPropose` A2A message. The confirmer will be unable to reproduce the correct hash.
*   **Recommendation:** Modify `submitHash` to return the `salt` used, or require the caller to provide it.

### [MEDIUM] Subgraph Filtering Scalability
*   **Location:** `AgentNotary.ts` -> `getAgentStatus`
*   **Description:** The SDK fetches up to 10,000 attestations and performs JSON parsing and filtering client-side.
*   **Impact:** As the platform grows, this will cause high memory usage and latency. It will eventually hit the 10k limit and return inaccurate "Suspicious" or "Unknown" ratings for high-volume agents.
*   **Recommendation:** Use EAS custom indexers or Subgraph "where" filters on the `decodedDataJson` fields directly.

---

## 3. Deployment & Devops Findings

### [LOW] Circular Dependency in Deployment
*   **Location:** `NotaryCore.test.js`
*   **Description:** `NotaryCore` requires Schema UIDs, but the Schema UIDs require the `NotaryResolver` address, which requires the `NotaryCore` address.
*   **Impact:** Deployment scripts are complex and prone to "stale address" bugs where a contract points to a previous iteration of another contract.
*   **Recommendation:** Use a factory pattern or update the `NotaryResolver` to allow setting the `notaryCore` address after deployment (with a one-time lock).

---

## 4. Positive Observations (Security Wins)

*   **Fair Credit System:** The `FeeRegistry` successfully prevents the owner from touching agent deposits. The `collectedFees` accounting is robust.
*   **Timelock:** The 48-hour timelock on fee changes is correctly implemented and provides a genuine exit window for users.
*   **Address Sorting:** The fix for address order in `computeHash` correctly prevents order-dependent hash mismatches.
*   **Outcome Commitment:** Including the `outcome` byte in the hash pre-image successfully prevents "outcome swapping" attacks.
