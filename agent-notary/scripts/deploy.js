const hre = require("hardhat");

/**
 * Deployment script — updated for security-fixed contracts.
 *
 * Changes from original:
 * - Uses collectFee (not deductFee) in FeeRegistry
 * - ownerWithdraw replaces withdraw
 * - computeHash signature includes outcome + sharedNonce
 */

const EAS_ADDRESSES = {
  sepolia:  "0xC2679fBD37d54388Ce493F1DB75320D236e1815e",
  base:     "0x4200000000000000000000000000000000000021",
  arbitrum: "0xbD75f629A22Dc1ceD33dDA0b68c546A1c035c458",
};
const SCHEMA_REGISTRIES = {
  sepolia:  "0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D",
  base:     "0x4200000000000000000000000000000000000020",
  arbitrum: "0x7b24C7f8AF365B4E308b6acb0A7dfc85d034Cb3",
};
const USDC_ADDRESSES = {
  sepolia:  "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
  base:     "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  arbitrum: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
};

async function main() {
  const network = hre.network.name;
  console.log(`Deploying to: ${network}`);

  const EAS_ADDRESS     = EAS_ADDRESSES[network]     ?? EAS_ADDRESSES.sepolia;
  const SCHEMA_REGISTRY = SCHEMA_REGISTRIES[network] ?? SCHEMA_REGISTRIES.sepolia;
  const USDC_ADDRESS    = USDC_ADDRESSES[network]    ?? USDC_ADDRESSES.sepolia;

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // 1. Deploy FeeRegistry
  const FeeRegistry = await hre.ethers.getContractFactory("FeeRegistry");
  const feeRegistry = await FeeRegistry.deploy(USDC_ADDRESS, deployer.address);
  await feeRegistry.waitForDeployment();
  console.log("FeeRegistry:", await feeRegistry.getAddress());

  // 1b. Deploy AuthorityRegistry
  const AuthorityRegistry = await hre.ethers.getContractFactory("AuthorityRegistry");
  const authorityRegistry = await AuthorityRegistry.deploy(await feeRegistry.getAddress(), deployer.address);
  await authorityRegistry.waitForDeployment();
  console.log("AuthorityRegistry:", await authorityRegistry.getAddress());

  // 2. Register schemas with zero resolver first
  const schemaRegistry = await hre.ethers.getContractAt("ISchemaRegistry", SCHEMA_REGISTRY);

  const witnessedSchema =
    "bytes32 interactionId,address submitter,address confirmer," +
    "bytes32 outcomeHash,uint256 submitterDeposit,uint256 confirmerDeposit," +
    "uint64 timestamp,uint256 chainId";
  const failureSchema =
    "bytes32 interactionId,address failingParty,address otherParty," +
    "uint256 submitterDeposit,uint256 confirmerDeposit," +
    "uint64 timestamp,uint256 chainId";

  let tx = await schemaRegistry.register(witnessedSchema, hre.ethers.ZeroAddress, false);
  let r  = await tx.wait();
  const wUID = r.logs[0].topics[1];

  tx = await schemaRegistry.register(failureSchema, hre.ethers.ZeroAddress, false);
  r  = await tx.wait();
  const fUID = r.logs[0].topics[1];

  // 3. Deploy NotaryCore
  const NotaryCore = await hre.ethers.getContractFactory("NotaryCore");
  const notaryCore = await NotaryCore.deploy(
    EAS_ADDRESS, await feeRegistry.getAddress(), wUID, fUID, deployer.address
  );
  await notaryCore.waitForDeployment();
  console.log("NotaryCore:", await notaryCore.getAddress());

  // 4. Deploy NotaryResolver
  const NotaryResolver = await hre.ethers.getContractFactory("NotaryResolver");
  const resolver = await NotaryResolver.deploy(
    EAS_ADDRESS, await notaryCore.getAddress(), deployer.address
  );
  await resolver.waitForDeployment();
  console.log("NotaryResolver:", await resolver.getAddress());

  // 5. Re-register schemas with resolver attached
  tx = await schemaRegistry.register(witnessedSchema, await resolver.getAddress(), false);
  r  = await tx.wait();
  const wFinal = r.logs[0].topics[1];

  tx = await schemaRegistry.register(failureSchema, await resolver.getAddress(), false);
  r  = await tx.wait();
  const fFinal = r.logs[0].topics[1];

  // 6. Wire FeeRegistry → NotaryCore & AuthorityRegistry
  await feeRegistry.setNotaryCore(await notaryCore.getAddress());
  await feeRegistry.setAuthorityRegistry(await authorityRegistry.getAddress());
  console.log("FeeRegistry wired to NotaryCore and AuthorityRegistry");

  // 7. Save addresses
  const fs = require("fs");
  const addresses = {
    network,
    feeRegistry:        await feeRegistry.getAddress(),
    authorityRegistry:  await authorityRegistry.getAddress(),
    notaryCore:         await notaryCore.getAddress(),
    notaryResolver:     await resolver.getAddress(),
    witnessedSchemaUID: wFinal,
    failureSchemaUID:   fFinal,
    usdcAddress:        USDC_ADDRESS,
    easAddress:         EAS_ADDRESS,
  };
  fs.writeFileSync(`./deployed.${network}.json`, JSON.stringify(addresses, null, 2));
  console.log(`Addresses saved to deployed.${network}.json`);
  console.log(addresses);
}

main().catch(console.error);
