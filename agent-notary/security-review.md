# Security Review Results: Agent Notary

This document provides a deep security and architectural review of the Agent Notary protocol. Several critical and major issues were identified that must be addressed before production deployment.

## Executive Summary

| Severity | Count | Status |
|---|---|---|
| 🔴 **Critical** | 1 | Protocol-breaking logic |
| 🟠 **Major** | 3 | Funds at risk / Protocol mismatch |
| 🟡 **Medium** | 2 | Privacy and Logic consistency |
| 🔵 **Minor** | 1 | Code quality |

---

## 🔴 Critical Issues

### 1. Address Order Mismatch in `computeHash`
**Location:** `NotaryCore.sol`, `AgentNotary.ts`

**Description:**
The `computeHash` function hashes the `submitterAddr` and `confirmerAddr` in a fixed order. However, the system allows either party to be the "submitter" (the first to call the contract). 
- Party A (Submitter) hashes: `(AddrA, AddrB)`
- Party B (Confirmer) hashes: `(AddrB, AddrA)`

**Impact:**
The hashes will **never match** on-chain unless the address values are identical (which is prevented by the self-attestation check). Every legitimate interaction will result in a `STATE_DISPUTED` instead of `STATE_WITNESSED`.

**Recommended Fix:**
Sort the addresses alphabetically inside the hashing function:
```solidity
address first = submitterAddr < confirmerAddr ? submitterAddr : confirmerAddr;
address second = submitterAddr < confirmerAddr ? confirmerAddr : submitterAddr;
return keccak256(abi.encodePacked(..., first, second, nonce));
```

---

## 🟠 Major Issues

### 2. Custodial Risk and Missing Withdrawals
**Location:** `FeeRegistry.sol`

**Description:**
The contract currently functions as a "black hole" for agent funds:
1. **No Exit:** There is no function for an agent to withdraw their deposited USDC.
2. **Owner Privilege:** The owner-only `withdraw()` function allows the contract owner to sweep the **entire** USDC balance, including unspent deposits belonging to agents.

**Impact:**
The contract is custodial. A compromise of the owner key allows the theft of all user deposits. Users have no way to recover funds if they stop using the service.

**Recommended Fix:**
1. Implement a `withdraw(uint256 amount)` function for users.
2. Track `totalFeesCollected` separately and restrict the owner's `withdraw` function to only that amount.

Here is an analysis of why the custodial risk is still problematic under your model and how you can resolve it while keeping your "fee-per-badge" goal. 
 
 ### 1. The "Unspent Balance" Problem
 
 Even if the fee is very low (e.g., $0.001), your FeeRegistry requires users to deposit() funds before they can call submitHash(). 
 - The Scenario: An agent deposits $5.00 to cover future interactions. After 100 interactions, they have spent $0.10. There is $4.90 of the user's money sitting 
 in your contract. 
 - The Risk: Since there is no user-withdrawal function, that $4.90 is effectively "trapped." Furthermore, your withdraw() function allows you (the owner) to take 
 that $4.90 immediately, even though you haven't "earned" it yet via an attestation. 
 
 In the eyes of a security auditor or a sophisticated AI agent/user: This looks like a "honey pot" where the developer can rug-pull all unspent user credits.
 
 ### 2. The "Fee Hike" Attack
 
 Because the owner can change the fee and there is no user-withdrawal: 
 1. Users deposit funds while the fee is $0.001. 
 2. The owner proposes a fee change to $1,000.00.
 3. After 48 hours, the next time an agent's automated script calls submitHash(), their entire unspent deposit is drained in a single transaction. 
 
 Without a way to "exit" the contract (withdraw), users are forced to trust that you will never maliciousy increase fees or stop the service.
 
 ### 3. Impact on "Agent Autonomy" 
 
 AI agents are increasingly designed to be "economically rational." If an agent's logic sees a contract where it can put money in but cannot get it out, it may
 flag that contract as high-risk or "scammy." This would hinder the "traction" you are looking for.
 
 ────────────────────────────────────────────────────────────────────────────────
 
 ### How to fix this while keeping your fee model
 
 You don't have to give up your $0.001 fee. You just need to make the contract non-custodial. Here are two ways: 
 
 #### Option A: Pay-As-You-Go (Recommended)
 
 Instead of a deposit() system, have the user pay the fee directly during the submitHash() call using USDC.transferFrom(). 
 - Pros: No funds are ever "trapped." Users only pay exactly what they owe at the moment of the service. 
 - Cons: Higher gas cost (one extra ERC20 transfer per call). However, on L2s like Base or Arbitrum, this cost is negligible.
 
 #### Option B: Fair Credit System 
 
 If you want to keep the deposit system (to save gas on repeated calls): 
 1. Add agentWithdraw(uint256 amount): Allow any user to withdraw their own balances[msg.sender].
 2. Separate Revenue from Deposits: Track a uint256 totalCollectedFees variable. When deductFee is called, increment this variable.
 3. Restrict Owner: Change the owner withdraw() function so it can only withdraw up to the totalCollectedFees.

### 3. Nonce Discrepancy (Protocol vs. Contract)
**Location:** `a2a-messages.ts` vs `NotaryCore.sol`

**Description:**
The A2A off-chain protocol defines two nonces (`submitterNonce` and `confirmerNonce`). However, the smart contract's `computeHash` and `submitHash` only accept a single `nonce` parameter.

**Impact:**
The SDK cannot faithfully implement the off-chain protocol. If parties agree on two nonces to prevent entropy manipulation, the contract cannot verify them.

**Recommended Fix:**
Update the `Slot` struct and `computeHash` to accept both nonces or a combined `bytes32` commitment.

### 4. SDK Performance and Scalability
**Location:** `AgentNotary.ts` -> `getAgentStatus()`

**Description:**
The SDK fetches up to 10,000 attestations and performs a string-search on the hex data for every status check.

**Impact:**
As the system scales, this will lead to:
1. Significant RPC/GraphQL costs.
2. Client-side browser/agent crashes due to memory exhaustion.
3. Inaccurate results once the interaction count exceeds the query limit.

**Recommended Fix:**
Utilize the EAS `recipient` field for the counterparty address or implement a specialized Subgraph/Indexer.

---

## 🟡 Medium Issues

### 5. Hash Brute-forcing and Privacy
**Location:** `NotaryCore.sol`

**Description:**
The `nonce` used for the hash is passed as a public parameter to `submitHash`. If the `outcomeData` is a standard JSON object with low entropy (e.g., `{"status":"ok"}`), an attacker can easily brute-force the hash to reveal the interaction details.

**Recommended Fix:**
Enforce the inclusion of a high-entropy secret salt *inside* the `outcomeData` object that is never revealed to the blockchain.

### 6. Decoupled Outcome and Hash
**Location:** `NotaryCore.sol` -> `submitHash()`

**Description:**
The `outcome` (ACCEPTED/FAILURE) is a separate parameter from the `outcomeHash`. It is possible for an agent to submit `outcome = ACCEPTED` while the hash actually represents a failure state in the underlying data.

**Recommended Fix:**
Include the `outcome` byte inside the `outcomeHash` calculation to ensure cryptographic commitment to the signal.

---

## 🔵 Minor Issues

### 7. Incomplete Input Validation
**Location:** `NotaryCore.sol`

**Description:**
During the second submission, the `counterparty` argument provided by the caller is not checked against the `slot.submitter`. 

**Recommended Fix:**
Add `require(counterparty == slot.submitter, "NotaryCore: counterparty mismatch");`.

---

## Final Recommendation

The **Agent Notary** protocol has a solid conceptual foundation, but the **Address Order Mismatch** and **Custodial Fee Registry** are blockers for any real-world deployment. Address these issues and update the SDK to handle address sorting before proceeding to Mainnet or L2 deployment.

