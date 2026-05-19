const { expect }  = require("chai");
const { ethers }  = require("hardhat");
const crypto = require("crypto");

// ── SDK helpers reproduced here to avoid module issues in test ──────────────

function freshSalt() {
  return crypto.randomBytes(32).toString("hex");
}

function freshNonce() {
  return ethers.hexlify(ethers.randomBytes(32));
}

function computeOutcomeHash(
  interactionId,
  outcomeData,
  timestamp,
  addrA,
  addrB,
  outcome,
  sharedNonce
) {
  const [first, second] = addrA.toLowerCase() < addrB.toLowerCase()
    ? [addrA, addrB]
    : [addrB, addrA];

  const hash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["bytes32", "bytes", "uint64", "address", "address", "uint8", "bytes32"],
    [interactionId, outcomeData, timestamp, first, second, outcome, sharedNonce]
  ));

  return hash;
}

/**
 * NotaryCore test suite — updated for dynamic deposit model.
 */
describe("NotaryCore — Dynamic Deposit Model", function () {

  let eas, schemaRegistry, usdc, feeRegistry, notaryCore;
  let deployer, agentA, agentB, agentC;

  // ── Deploy helpers ──────────────────────────────────────────────────────

  async function deployFull() {
    [deployer, agentA, agentB, agentC] = await ethers.getSigners();

    const SR = await ethers.getContractFactory("SchemaRegistry");
    schemaRegistry = await SR.deploy();

    const EAS = await ethers.getContractFactory("EAS");
    eas = await EAS.deploy(await schemaRegistry.getAddress());

    const USDC = await ethers.getContractFactory("MockUSDC");
    usdc = await USDC.deploy();
    await usdc.mint(agentA.address, 10_000_000n); // $10
    await usdc.mint(agentB.address, 10_000_000n);
    await usdc.mint(agentC.address, 10_000_000n);

    const FR = await ethers.getContractFactory("FeeRegistry");
    feeRegistry = await FR.deploy(await usdc.getAddress(), deployer.address);

    const witnessedSchema =
      "bytes32 interactionId,address submitter,address confirmer," +
      "bytes32 outcomeHash,uint256 amountBurned,uint16 score," +
      "uint64 timestamp,uint256 chainId";
    const failureSchema =
      "bytes32 interactionId,address failingParty,address otherParty," +
      "uint256 amountBurned,uint16 score," +
      "uint64 timestamp,uint256 chainId";

    let tx = await schemaRegistry.register(witnessedSchema, ethers.ZeroAddress, false);
    let r  = await tx.wait();
    const wUID = r.logs[0].topics[1];

    tx = await schemaRegistry.register(failureSchema, ethers.ZeroAddress, false);
    r  = await tx.wait();
    const fUID = r.logs[0].topics[1];

    const NR = await ethers.getContractFactory("NotaryResolver");
    const resolver = await NR.deploy(await eas.getAddress(), ethers.ZeroAddress, deployer.address);

    tx = await schemaRegistry.register(witnessedSchema, await resolver.getAddress(), false);
    r  = await tx.wait();
    const wFinal = r.logs[0].topics[1];
    tx = await schemaRegistry.register(failureSchema, await resolver.getAddress(), false);
    r  = await tx.wait();
    const fFinal = r.logs[0].topics[1];

    const NC = await ethers.getContractFactory("NotaryCore");
    notaryCore = await NC.deploy(
      await eas.getAddress(),
      await feeRegistry.getAddress(),
      wFinal, fFinal,
      deployer.address
    );
    await resolver.setNotaryCore(await notaryCore.getAddress());
    await feeRegistry.setNotaryCore(await notaryCore.getAddress());
  }

  // shared interaction params
  function makeInteraction(overrides = {}) {
    const interactionId  = ethers.encodeBytes32String("job-001");
    const outcomeData    = ethers.toUtf8Bytes(JSON.stringify({ jobId: "001", status: "ok", _salt: freshSalt() }));
    const timestamp      = Math.floor(Date.now() / 1000);
    const sharedNonce    = freshNonce();
    return { interactionId, outcomeData, timestamp, sharedNonce, ...overrides };
  }

  // ── Setup ───────────────────────────────────────────────────────────────

  beforeEach(deployFull);

  describe("Dynamic Deposits", () => {
    it("produces the same hash regardless of address argument order", async () => {
      const { interactionId, outcomeData, timestamp, sharedNonce } = makeInteraction();

      const hashAB = await notaryCore.computeHash(
        interactionId, outcomeData, timestamp,
        agentA.address, agentB.address, 1, sharedNonce
      );
      const hashBA = await notaryCore.computeHash(
        interactionId, outcomeData, timestamp,
        agentB.address, agentA.address, 1, sharedNonce
      );

      expect(hashAB).to.equal(hashBA, "hash must be order-independent");
    });

    it("WITNESSED: both parties produce matching hashes and deposits are collected and burned", async () => {
      const { interactionId, outcomeData, timestamp, sharedNonce } = makeInteraction();

      const hash = await notaryCore.computeHash(
        interactionId, outcomeData, timestamp,
        agentA.address, agentB.address, 1, sharedNonce
      );

      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentA).deposit(50000n);
      await usdc.connect(agentB).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentB).deposit(50000n);

      await notaryCore.connect(agentA).submitHash(
        interactionId, hash, 1, agentB.address, 24, sharedNonce, 50000n
      );

      const tx = await notaryCore.connect(agentB).confirmHash(
        interactionId, hash, 1, agentA.address, sharedNonce, 50000n
      );
      await expect(tx).to.emit(notaryCore, "WitnessedAttestation");

      const slot = await notaryCore.slots(interactionId);
      expect(slot.state).to.equal(1n); // STATE_WITNESSED
      expect(slot.submitterDeposit).to.equal(50000n);
      expect(slot.confirmerDeposit).to.equal(50000n);

      expect(await feeRegistry.totalBurned()).to.equal(90000n); // 90% of (50000 + 50000)
      expect(await feeRegistry.withdrawableFees()).to.equal(10000n); // 10% share
      expect(await feeRegistry.escrowedFees()).to.equal(0n);
    });
  });

  describe("Fair Credit System", () => {
    it("agents can deposit and withdraw their own unused balance", async () => {
      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 5_000_000n);
      await feeRegistry.connect(agentA).deposit(5_000_000n);

      expect(await feeRegistry.balances(agentA.address)).to.equal(5_000_000n);

      // Withdraw it all back
      await feeRegistry.connect(agentA).agentWithdraw(5_000_000n);
      expect(await feeRegistry.balances(agentA.address)).to.equal(0n);
    });

    it("owner cannot withdraw agent deposits in escrow — only withdrawableFees", async () => {
      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 100_000n);
      await feeRegistry.connect(agentA).deposit(100_000n);
      
      const { interactionId, sharedNonce } = makeInteraction();
      await notaryCore.connect(agentA).submitHash(interactionId, ethers.ZeroHash, 1, agentB.address, 24, sharedNonce, 100_000n);

      // Now 100k is in escrowedFees. withdrawableFees is 0.
      expect(await feeRegistry.escrowedFees()).to.equal(100_000n);
      expect(await feeRegistry.withdrawableFees()).to.equal(0n);

      await expect(
        feeRegistry.ownerWithdraw(deployer.address, 100_000n)
      ).to.be.revertedWith("FeeRegistry: amount exceeds withdrawable fees");
    });

    it("allows owner to update the minimum fee", async function () {
      const newMinFee = 100000n;
      await feeRegistry.setMinFee(newMinFee);
      expect(await feeRegistry.minFee()).to.equal(newMinFee);

      // Verify it's enforced
      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentA).deposit(50000n);
      
      const { interactionId, sharedNonce } = makeInteraction();
      await expect(
        notaryCore.connect(agentA).submitHash(interactionId, ethers.ZeroHash, 1, agentB.address, 24, sharedNonce, 50000n)
      ).to.be.revertedWith("FeeRegistry: amount below minimum fee");
    });
  });

  describe("Outcome scenarios", () => {
    it("DECLINED: confirmer sends CANCEL, both deposits are refunded", async () => {
      const { interactionId, outcomeData, timestamp, sharedNonce } = makeInteraction();
      const hash = await notaryCore.computeHash(interactionId, outcomeData, timestamp, agentA.address, agentB.address, 1, sharedNonce);

      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentA).deposit(50000n);
      await usdc.connect(agentB).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentB).deposit(50000n);

      await notaryCore.connect(agentA).submitHash(interactionId, hash, 1, agentB.address, 24, sharedNonce, 50000n);

      const balABefore = await feeRegistry.balances(agentA.address); // 0
      const balBBefore = await feeRegistry.balances(agentB.address); // 50000

      const dummyHash = ethers.hexlify(ethers.randomBytes(32));
      const tx = await notaryCore.connect(agentB).confirmHash(interactionId, dummyHash, 2, agentA.address, sharedNonce, 50000n);
      await expect(tx).to.emit(notaryCore, "Declined");

      expect(await feeRegistry.balances(agentA.address)).to.equal(50000n);
      expect(await feeRegistry.balances(agentB.address)).to.equal(50000n);
      expect(await feeRegistry.escrowedFees()).to.equal(0n);
    });

    it("EXPIRED: markExpired after timeout refunds submitter", async () => {
      const { interactionId, outcomeData, timestamp, sharedNonce } = makeInteraction();
      const hash = await notaryCore.computeHash(interactionId, outcomeData, timestamp, agentA.address, agentB.address, 1, sharedNonce);
      
      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentA).deposit(50000n);
      
      await notaryCore.connect(agentA).submitHash(interactionId, hash, 1, agentB.address, 1, sharedNonce, 50000n);

      await ethers.provider.send("evm_increaseTime", [3601]);
      await ethers.provider.send("evm_mine");
      
      await notaryCore.markExpired(interactionId);
      expect(await feeRegistry.balances(agentA.address)).to.equal(50000n);
      expect(await feeRegistry.escrowedFees()).to.equal(0n);
    });

    it("FAILED: confirmer sends FAILURE → both deposits are collected and burned", async () => {
      const { interactionId, outcomeData, timestamp, sharedNonce } = makeInteraction();
      const hashA = await notaryCore.computeHash(interactionId, outcomeData, timestamp, agentA.address, agentB.address, 1, sharedNonce);
      
      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentA).deposit(50000n);
      await notaryCore.connect(agentA).submitHash(interactionId, hashA, 1, agentB.address, 24, sharedNonce, 50000n);

      await usdc.connect(agentB).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentB).deposit(50000n);
      const hashB = await notaryCore.computeHash(interactionId, outcomeData, timestamp, agentA.address, agentB.address, 3, sharedNonce);
      
      const tx = await notaryCore.connect(agentB).confirmHash(interactionId, hashB, 3, agentA.address, sharedNonce, 50000n);
      await expect(tx).to.emit(notaryCore, "FailureAttestation");
      
      expect(await feeRegistry.totalBurned()).to.equal(90000n);
      expect(await feeRegistry.withdrawableFees()).to.equal(10000n);
    });

    it("enters DISPUTED state on hash mismatch", async () => {
      const { interactionId, outcomeData, timestamp, sharedNonce } = makeInteraction();
      
      const hashA = await notaryCore.computeHash(interactionId, outcomeData, timestamp, agentA.address, agentB.address, 1, sharedNonce);
      
      // agentB uses a different hash (mismatch)
      const fakeData = ethers.toUtf8Bytes("wrong data");
      const hashB = await notaryCore.computeHash(interactionId, fakeData, timestamp, agentA.address, agentB.address, 1, sharedNonce);

      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentA).deposit(50000n);
      await usdc.connect(agentB).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentB).deposit(50000n);

      await notaryCore.connect(agentA).submitHash(interactionId, hashA, 1, agentB.address, 24, sharedNonce, 50000n);
      await notaryCore.connect(agentB).confirmHash(interactionId, hashB, 1, agentA.address, sharedNonce, 50000n);

      const slot = await notaryCore.slots(interactionId);
      expect(slot.state).to.equal(3n); // STATE_DISPUTED
      expect(await feeRegistry.totalBurned()).to.equal(90000n);
    });
  });

  describe("Negative scenarios", () => {
    it("blocks submission if agent balance < depositAmount", async () => {
      const { interactionId, outcomeHash, sharedNonce } = makeInteraction();
      // agentC has 0 balance, trying to submit with min fee
      await expect(
        notaryCore.connect(agentC).submitHash(
          interactionId, ethers.ZeroHash, 1, agentA.address, 24, sharedNonce, 50000n
        )
      ).to.be.revertedWith("FeeRegistry: insufficient balance");
    });

    it("blocks confirmation if confirmer balance < depositAmount", async () => {
      const { interactionId, outcomeData, timestamp, sharedNonce } = makeInteraction();
      const hash = await notaryCore.computeHash(interactionId, outcomeData, timestamp, agentA.address, agentB.address, 1, sharedNonce);
      
      await usdc.connect(agentA).approve(await feeRegistry.getAddress(), 50000n);
      await feeRegistry.connect(agentA).deposit(50000n);
      await notaryCore.connect(agentA).submitHash(interactionId, hash, 1, agentB.address, 24, sharedNonce, 50000n);

      // agentB has 0 balance
      await expect(
        notaryCore.connect(agentB).confirmHash(interactionId, hash, 1, agentA.address, sharedNonce, 50000n)
      ).to.be.revertedWith("FeeRegistry: insufficient balance");
    });

    it("fails on self-attestation", async () => {
      const { interactionId, sharedNonce } = makeInteraction();
      await expect(
        notaryCore.connect(agentA).submitHash(
          interactionId, ethers.ZeroHash, 1, agentA.address, 24, sharedNonce, 50000n
        )
      ).to.be.revertedWith("NotaryCore: self-attestation");
    });
  });
});
