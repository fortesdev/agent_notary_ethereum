const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("AuthorityRegistry & FeeRegistry Dynamic Model", function () {
  let usdc, feeRegistry, authorityRegistry;
  let deployer, user, agent;

  beforeEach(async function () {
    [deployer, user, agent] = await ethers.getSigners();

    const USDC = await ethers.getContractFactory("MockUSDC");
    usdc = await USDC.deploy();

    const FR = await ethers.getContractFactory("FeeRegistry");
    feeRegistry = await FR.deploy(await usdc.getAddress(), deployer.address);

    const AR = await ethers.getContractFactory("AuthorityRegistry");
    authorityRegistry = await AR.deploy(await feeRegistry.getAddress(), deployer.address);

    await feeRegistry.setAuthorityRegistry(await authorityRegistry.getAddress());
  });

  it("should allow an agent to register a permission with a user signature and custom deposit", async function () {
    const spendingCap = 1000000;
    const expiry = 2000000000;
    const scope = ethers.ZeroHash;
    const metadataURI = "ipfs://test";
    const nonce = 0;
    const depositAmount = 50000n;

    await usdc.mint(agent.address, depositAmount);
    await usdc.connect(agent).approve(await feeRegistry.getAddress(), depositAmount);
    await feeRegistry.connect(agent).deposit(depositAmount);

    const messageHash = ethers.solidityPackedKeccak256(
      ["uint256", "address", "address", "address", "uint256", "uint64", "string", "uint256"],
      [31337, await authorityRegistry.getAddress(), user.address, agent.address, spendingCap, expiry, metadataURI, nonce]
    );
    const signature = await user.signMessage(ethers.getBytes(messageHash));

    await expect(authorityRegistry.connect(agent).registerPermission(
      user.address, agent.address, spendingCap, expiry, [scope], metadataURI, signature, depositAmount
    )).to.emit(authorityRegistry, "PermissionRegistered");

    expect(await feeRegistry.totalBurned()).to.equal((depositAmount * 90n) / 100n);
    expect(await feeRegistry.withdrawableFees()).to.equal(depositAmount - (depositAmount * 90n) / 100n);
  });

  it("should correctly check authority and spending caps", async function () {
    const spendingCap = 1000;
    const expiry = 2000000000;
    const scope = ethers.keccak256(ethers.toUtf8Bytes("test"));
    const metadataURI = "meta";
    const nonce = 0;
    
    const messageHash = ethers.solidityPackedKeccak256(
      ["uint256", "address", "address", "address", "uint256", "uint64", "string", "uint256"],
      [31337, await authorityRegistry.getAddress(), user.address, agent.address, spendingCap, expiry, metadataURI, nonce]
    );
    const signature = await user.signMessage(ethers.getBytes(messageHash));

    const depositAmount = 50000n;
    await usdc.mint(agent.address, depositAmount);
    await usdc.connect(agent).approve(await feeRegistry.getAddress(), depositAmount);
    await feeRegistry.connect(agent).deposit(depositAmount);

    await authorityRegistry.connect(agent).registerPermission(
      user.address, agent.address, spendingCap, expiry, [scope], metadataURI, signature, depositAmount
    );

    expect(await authorityRegistry.checkAuthority(agent.address, user.address, scope, 500)).to.be.true;
    expect(await authorityRegistry.checkAuthority(agent.address, user.address, scope, 1001)).to.be.false;

    await authorityRegistry.recordAction(agent.address, user.address, 700);

    expect(await authorityRegistry.checkAuthority(agent.address, user.address, scope, 400)).to.be.false;
    expect(await authorityRegistry.checkAuthority(agent.address, user.address, scope, 300)).to.be.true;
  });
});
