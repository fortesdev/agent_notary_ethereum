// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./interfaces/IFeeRegistry.sol";

/**
 * @title AuthorityRegistry
 * @notice Global index of AI agent permissions aligned with ERC-7715.
 */
contract AuthorityRegistry is Ownable {
    using ECDSA for bytes32;

    struct PermissionRecord {
        address delegator;
        uint256 spendingCap;
        uint256 spent;
        uint64 expiry;
        bool revoked;
        uint256 nonce; // Prevents replaying the same signature
        mapping(bytes32 => bool) scopes;
        string metadataURI;
    }

    IFeeRegistry public feeRegistry;
    address public notaryCore;

    // agent => delegator => Record
    mapping(address => mapping(address => PermissionRecord)) private _records;

    event PermissionRegistered(address indexed delegator, address indexed delegate, uint64 expiry);
    event PermissionRevoked(address indexed delegator, address indexed delegate);
    event ActionRecorded(address indexed delegator, address indexed delegate, uint256 amount);

    constructor(address _feeRegistry, address _initialOwner) {
        feeRegistry = IFeeRegistry(_feeRegistry);
        _transferOwnership(_initialOwner);
    }

    modifier onlyAuthorizedService() {
        require(msg.sender == notaryCore || msg.sender == owner(), "AuthorityRegistry: unauthorized");
        _;
    }

    function setFeeRegistry(address _feeRegistry) external onlyOwner {
        feeRegistry = IFeeRegistry(_feeRegistry);
    }

    function setNotaryCore(address _notaryCore) external onlyOwner {
        notaryCore = _notaryCore;
    }

    /**
     * @notice Register a new permission. Triggered by the Agent.
     * @param delegator The user granting permission.
     * @param delegate The agent receiving permission.
     * @param spendingCap Max USDC lamports.
     * @param expiry Unix timestamp.
     * @param scopes List of keccak256 hashed category names.
     * @param metadataURI IPFS/Arweave link.
     * @param signature Delegator's signature over the parameters.
     * @param depositAmount Amount of USDC to invest in this registration.
     */
    function registerPermission(
        address delegator,
        address delegate,
        uint256 spendingCap,
        uint64 expiry,
        bytes32[] calldata scopes,
        string calldata metadataURI,
        bytes calldata signature,
        uint256 depositAmount
    ) external {
        // 1. Collect registration deposit from the agent (delegate)
        feeRegistry.collectCustomFee(delegate, depositAmount);

        PermissionRecord storage record = _records[delegate][delegator];
        uint256 currentNonce = record.nonce;

        // 2. Verify Signature (Includes ChainID and Nonce to prevent replay)
        bytes32 messageHash = keccak256(abi.encodePacked(
            block.chainid,
            address(this),
            delegator,
            delegate,
            spendingCap,
            expiry,
            metadataURI,
            currentNonce
        ));
        
        require(messageHash.toEthSignedMessageHash().recover(signature) == delegator, "Invalid signature");

        // 3. Store Record
        record.delegator = delegator;
        record.spendingCap = spendingCap;
        record.expiry = expiry;
        record.metadataURI = metadataURI;
        record.revoked = false;
        record.nonce = currentNonce + 1;
        
        for (uint i = 0; i < scopes.length; i++) {
            record.scopes[scopes[i]] = true;
        }

        // 4. Settle the fee (Burn/Collect)
        if (depositAmount > 0) {
            feeRegistry.settleFees(depositAmount);
        }

        emit PermissionRegistered(delegator, delegate, expiry);
    }

    function revokePermission(address delegate) external {
        _records[delegate][msg.sender].revoked = true;
        emit PermissionRevoked(msg.sender, delegate);
    }

    /**
     * @notice External query for services to verify authority.
     */
    function checkAuthority(
        address delegate,
        address delegator,
        bytes32 scope,
        uint256 amount
    ) external view returns (bool) {
        PermissionRecord storage record = _records[delegate][delegator];
        
        if (record.delegator == address(0)) return false;
        if (record.revoked) return false;
        if (record.expiry != 0 && record.expiry < block.timestamp) return false;
        if (!record.scopes[scope]) return false;
        if (record.spent + amount > record.spendingCap) return false;
        
        return true;
    }

    /**
     * @notice Record a successful action. Only NotaryCore or Owner can call.
     */
    function recordAction(
        address delegate,
        address delegator,
        uint256 amount
    ) external onlyAuthorizedService {
        PermissionRecord storage record = _records[delegate][delegator];
        require(record.delegator != address(0), "Not found");
        require(!record.revoked, "Revoked");
        require(record.spent + amount <= record.spendingCap, "Cap exceeded");
        
        record.spent += amount;
        emit ActionRecorded(delegator, delegate, amount);
    }

    function getPermission(address delegate, address delegator) external view returns (
        address delegatorAddr,
        uint256 spendingCap,
        uint256 spent,
        uint64 expiry,
        bool revoked,
        uint256 nonce,
        string memory metadataURI
    ) {
        PermissionRecord storage record = _records[delegate][delegator];
        return (
            record.delegator,
            record.spendingCap,
            record.spent,
            record.expiry,
            record.revoked,
            record.nonce,
            record.metadataURI
        );
    }
}
