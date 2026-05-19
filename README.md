# Agent Notary

Permanent on-chain witnessed badge attestations for AI agent interactions, built on the [Ethereum Attestation Service (EAS)](https://attest.org).

## What it does

Two AI agents complete an interaction. Each independently submits a cryptographic hash of the outcome to the Agent Notary contract. When both hashes match, a permanent **Witnessed Badge** is written to EAS. No trusted issuer. No signing key. No central authority.

## State machine

| State | Meaning | Badge |
|---|---|---|
| `WITNESSED` | Both submitted matching ACCEPTED hashes | ✅ Witnessed Badge |
| `FAILED` | Confirmer penalized Submitter | ❌ Failure Badge (Submitter) |
| `DISPUTED` | Conflicting outcomes or hash mismatch | — No badge |
| `DECLINED` | Confirmer sent CANCEL (polite decline) | — No badge, both refunded |
| `EXPIRED` | Confirmer was silent past timeout | — No badge, no cost to confirmer |

**Key design decisions:**
- Silence is free rejection — no penalty for non-participation
- Failure Badges require bilateral submission — both parties burn their stakes on FAILURE.
- CANCEL is a polite decline (both parties are refunded, no badge issued).
- NotaryCore has no owner and no upgradeability — the matching logic is immutable

## Fee & Reputation System (ERC-8004)

The Ethereum implementation follows a **Proof-of-Burn** model to ensure Sybil resistance and alignment with **ERC-8004** principles.

- **Minimum Fee**: A minimum deposit of **0.05 USDC** is required for both parties to participate in an interaction.
- **Escrow & Settlement**: Deposits are held in an **escrow** pool in the FeeRegistry and cannot be touched by the owner while the interaction is pending.
- **90/10 Split**: Upon successful settlement (Witnessed, Failed, or Disputed):
    - **90% is burned**: Tokens are transferred to the dead address (`0x0...dEaD`), permanently removing them from supply.
    - **10% is withdrawable**: This owner share moves from escrow to a separate withdrawable pool.
- **ERC-8004 Compatibility**: Attestations written to EAS include the `score` (0-1000) and the `amountBurned`, making them easily indexable by reputation aggregators.
- **Refunds**: Funds are **refunded** from escrow on DECLINED and EXPIRED (no service rendered). Owner can only withdraw `withdrawableFees` — never pending agent deposits in escrow.
- **Security Decisions**:
    - **No custodial risk**: Pending stakes held in escrow; owner only withdraws settled shares (FIX #A).

## Project structure

```
agent-notary/
├── contracts/
│   ├── AuthorityRegistry.sol  ERC-7715 indexed agent permissions (New)
│   ├── FeeRegistry.sol        Fee management, 48h timelocked changes
│   ├── NotaryCore.sol         Core matching logic, mutable until locked
│   ├── NotaryResolver.sol     EAS resolver, restricts badge creation
│   └── interfaces/
│       └── IFeeRegistry.sol
├── scripts/
│   └── deploy.js              Deployment script for L2s/Sepolia
├── sdk/
│   ├── AgentNotary.ts         TypeScript SDK for agent integration
│   ├── a2a-messages.ts        A2A off-chain message type definitions
│   └── index.ts               Barrel exports
├── test/
│   └── NotaryCore.test.js     Hardhat tests
├── .env.example
├── hardhat.config.js
├── package.json
└── tsconfig.json
```

## Quick start

```bash
# Install dependencies
npm install

# Copy and fill in environment variables
cp .env.example .env

# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

## Deployment

The deployment script supports Sepolia, Base, and Arbitrum.

1. **Environment Setup**:
   Ensure your `.env` file has the following variables:
   ```bash
   PRIVATE_KEY=0x...
   SEPOLIA_URL=https://...
   BASE_URL=https://...
   ARBITRUM_URL=https://...
   ETHERSCAN_API_KEY=...
   BASESCAN_API_KEY=...
   ARBISCAN_API_KEY=...
   ```

2. **Run Deployment**:
   ```bash
   # Deploy to Sepolia (Testnet)
   npm run deploy:sepolia

   # Deploy to Base (Mainnet)
   npm run deploy:base

   # Deploy to Arbitrum (Mainnet)
   npm run deploy:arbitrum
   ```

3. **Post-Deployment**:
   After deployment, a `deployed.{network}.json` file will be generated. Copy these addresses into your SDK configuration.

## Agent integration (SDK)

```typescript
import { AgentNotary } from "./sdk/AgentNotary";

const notary = new AgentNotary(process.env.SEPOLIA_URL!, process.env.AGENT_PRIVATE_KEY!);

// Submitter side
const nonce = notary.freshNonce();
await notary.submit({
  interactionId:   "0x3a5f...",   // agreed off-chain via A2A handshake
  outcomeData:     { jobId: "abc", status: "completed", completedAt: 1720000000 },
  agreedTimestamp: 1720000000,
  counterparty:    "0xDEF...",
  expirationHours: 24,
  outcome:         1,             // ACCEPTED
}, nonce);

// Query agent status
const info = await notary.getAgentStatus("0xABC...");
console.log(info.status); // "Active" | "Established" | "Verified" | "Suspicious" | "Unknown"
```

## A2A handshake

Before submitting to the chain, both parties agree on the hash pre-image off-chain:

1. **Submitter → Confirmer**: `notary/propose` message (see `sdk/a2a-messages.ts`)
2. **Confirmer → Submitter**: `notary/acknowledge` message
3. Both independently call `notary.submit()` — no further coordination needed

## Agent status

Computed entirely off-chain from EAS attestation data. No admin can influence it.

| Status | Condition |
|---|---|
| `Suspicious` | >50% of interactions ended in failure |
| `Verified` | 10,000+ witnessed badges AND ≥80% success rate |
| `Established` | 100+ witnessed badges AND ≥80% success rate |
| `Active` | 1+ witnessed badge in the last 30 days |
| `Unknown` | None of the above |

## Ownership & Mutability

All contracts are initially `Ownable`. This allows the owner to update key parameters (EAS addresses, Schema UIDs, Registry links) during the initial rollout.

| Contract | Owner | Mutable Fields |
|---|---|---|
| `NotaryCore` | Deployer | EAS, FeeRegistry, Schema UIDs |
| `AuthorityRegistry` | Deployer | FeeRegistry |
| `NotaryResolver` | Deployer | NotaryCore address |
| `FeeRegistry` | Deployer | NotaryCore, AuthorityRegistry, Fees |

### Locking the Contracts
To make the DApp fully immutable (matching its original design intent), the owner must call `renounceOwnership()` on all contracts. **Once renounced, parameters can never be changed again.**

### Fee Management
Fee changes in `FeeRegistry` are protected by a **48-hour timelock**.
1. Owner calls `proposeSubmissionFeeChange` or `proposeRegistrationFeeChange`.
2. Wait 48 hours.
3. Owner calls `applySubmissionFeeChange` or `applyRegistrationFeeChange`.

## Sepolia EAS addresses

| Contract | Address |
|---|---|
| EAS | `0xC2679fBD37d54388Ce493F1DB75320D236e1815e` |
| SchemaRegistry | `0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D` |
| USDC (Circle) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

## License

MIT
