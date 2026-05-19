import { BigInt, BigDecimal, Bytes, crypto, ethereum } from "@graphprotocol/graph-ts";
import {
  HashSubmitted,
  WitnessedAttestation,
  FailureAttestation
} from "../generated/NotaryCore/NotaryCore";
import {
  PermissionRegistered
} from "../generated/AuthorityRegistry/AuthorityRegistry";
import { Agent, Interaction, Permission } from "../generated/schema";

function getOrCreateAgent(address: Bytes): Agent {
  let id = address.toHexString().toLowerCase();
  let agent = Agent.load(id);
  if (!agent) {
    agent = new Agent(id);
    agent.witnessedCount = BigInt.fromI32(0);
    agent.failureCount = BigInt.fromI32(0);
    agent.disputedCount = BigInt.fromI32(0);
    agent.successRate = BigDecimal.fromString("0");
    agent.status = "UNKNOWN";
    agent.lastInteractionAt = BigInt.fromI32(0);
  }
  return agent;
}

function updateAgentStatus(agent: Agent): void {
  let total = agent.witnessedCount.plus(agent.failureCount).toBigDecimal();
  if (total.gt(BigDecimal.fromString("0"))) {
    agent.successRate = agent.witnessedCount.toBigDecimal().div(total);
  }

  if (agent.failureCount.gt(BigInt.fromI32(10)) && agent.successRate.lt(BigDecimal.fromString("0.5"))) {
    agent.status = "SUSPICIOUS";
  } else if (agent.witnessedCount.gt(BigInt.fromI32(1000))) {
    agent.status = "VERIFIED";
  } else if (agent.witnessedCount.gt(BigInt.fromI32(100))) {
    agent.status = "ESTABLISHED";
  } else if (agent.witnessedCount.gt(BigInt.fromI32(0))) {
    agent.status = "ACTIVE";
  }
}

export function handleHashSubmitted(event: HashSubmitted): void {
  let interaction = new Interaction(event.params.interactionId.toHexString());
  let agent = getOrCreateAgent(event.params.party);
  
  interaction.submitter = agent.id;
  interaction.state = "PENDING";
  interaction.createdAt = event.block.timestamp;
  interaction.expiresAt = event.block.timestamp.plus(BigInt.fromI32(86400)); // Default fallback
  interaction.save();
}

export function handleWitnessed(event: WitnessedAttestation): void {
  let interaction = Interaction.load(event.params.interactionId.toHexString());
  if (interaction) {
    interaction.state = "WITNESSED";
    interaction.outcomeHash = event.params.outcomeHash.toHexString();
    interaction.save();

    let submitter = getOrCreateAgent(event.params.submitter);
    let confirmer = getOrCreateAgent(event.params.confirmer);

    submitter.witnessedCount = submitter.witnessedCount.plus(BigInt.fromI32(1));
    confirmer.witnessedCount = confirmer.witnessedCount.plus(BigInt.fromI32(1));
    
    updateAgentStatus(submitter);
    updateAgentStatus(confirmer);
    
    submitter.save();
    confirmer.save();
  }
}

export function handleFailure(event: FailureAttestation): void {
  let interaction = Interaction.load(event.params.interactionId.toHexString());
  if (interaction) {
    interaction.state = "FAILED";
    interaction.save();

    let failingParty = getOrCreateAgent(event.params.failingParty);
    failingParty.failureCount = failingParty.failureCount.plus(BigInt.fromI32(1));
    updateAgentStatus(failingParty);
    failingParty.save();
  }
}

export function handlePermissionRegistered(event: PermissionRegistered): void {
  let id = event.params.delegate.toHexString() + "-" + event.params.delegator.toHexString();
  let permission = new Permission(id);
  
  permission.delegate = event.params.delegate.toHexString().toLowerCase();
  permission.delegator = event.params.delegator.toHexString().toLowerCase();
  permission.expiry = event.params.expiry;
  permission.revoked = false;
  permission.spent = BigInt.fromI32(0);
  permission.spendingCap = BigInt.fromI32(0); // This would be fetched from storage if needed
  permission.save();
}
