// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title FeeRegistry
 * @notice Logic for depositing and collecting funds as reputation investments.
 *
 * Key design decisions:
 *
 * 1. Non-custodial agent balances:
 *    Agents deposit USDC credit upfront (saves gas vs. per-tx transferFrom).
 *    Any agent can withdraw their own unused balance at any time with
 *    agentWithdraw(). Their funds are never at risk.
 *
 * 2. Separated revenue accounting:
 *    collectedFees tracks only funds actually earned via collection.
 *    The owner withdraw() is hard-capped to collectedFees — it cannot
 *    touch agent deposits under any circumstance.
 *
 * 3. Dynamic "Proof-of-Stake" model:
 *    In this version, there are no hardcoded fees. Each interaction or registration
 *    specifies the amount to be "invested" (burnt/collected) from the agent's credit.
 *
 * INVARIANT (enforced at all times):
 *    sum(balances) + collectedFees <= USDC.balanceOf(address(this))
 *    owner can only withdraw collectedFees, never agent balances.
 */
contract FeeRegistry is Ownable {
    using SafeERC20 for IERC20;

    IERC20  public usdc;
    address public notaryCore;
    address public authorityRegistry;

    // ── Configuration ──────────────────────────────────────────────────────
    uint256 public minFee = 50_000; // 0.05 USDC (6 decimals)

    // ── Agent credit balances ──────────────────────────────────────────────
    // Agents can withdraw their own balance at any time.
    mapping(address => uint256) public balances;

    // ── Revenue and Burn tracking ──────────────────────────────────────────
    // Funds currently held in escrow (pending interactions).
    uint256 public escrowedFees;
    // Owner withdraw() is capped to this amount only (accumulated 10% shares).
    uint256 public withdrawableFees;
    // Total amount of USDC burned (90% share).
    uint256 public totalBurned;

    // ── Events ─────────────────────────────────────────────────────────────
    event Deposited(address indexed agent, uint256 amount);
    event AgentWithdrew(address indexed agent, uint256 amount);
    event FeeCollected(address indexed agent, uint256 amount);
    event FeeSettled(uint256 totalAmount, uint256 burned, uint256 ownerShare);
    event FeeRefunded(address indexed agent, uint256 amount);
    event OwnerWithdrew(address indexed to, uint256 amount);
    event MinFeeUpdated(uint256 newMinFee);
    event NotaryCoreSet(address indexed notaryCore);
    event AuthorityRegistrySet(address indexed authorityRegistry);

    constructor(address _usdc, address _initialOwner) {
        usdc = IERC20(_usdc);
        _transferOwnership(_initialOwner);
    }

    modifier onlyAuthorizedService() {
        require(msg.sender == notaryCore || msg.sender == authorityRegistry, "FeeRegistry: caller not authorized service");
        _;
    }

    /// @notice Update minimum fee requirement.
    function setMinFee(uint256 _minFee) external onlyOwner {
        minFee = _minFee;
        emit MinFeeUpdated(_minFee);
    }

    /// @notice Change USDC token address.
    function setUsdc(address _usdc) external onlyOwner {
        usdc = IERC20(_usdc);
    }

    /// @notice Wire NotaryCore.
    function setNotaryCore(address _notaryCore) external onlyOwner {
        notaryCore = _notaryCore;
        emit NotaryCoreSet(_notaryCore);
    }

    /// @notice Wire AuthorityRegistry.
    function setAuthorityRegistry(address _authorityRegistry) external onlyOwner {
        authorityRegistry = _authorityRegistry;
        emit AuthorityRegistrySet(_authorityRegistry);
    }

    // ── Agent-facing functions ─────────────────────────────────────────────

    /// @notice Deposit USDC credit for future reputation investments.
    function deposit(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw unused credit balance.
     * Agents can always recover unspent deposits.
     */
    function agentWithdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "FeeRegistry: insufficient balance");
        balances[msg.sender] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit AgentWithdrew(msg.sender, amount);
    }

    // ── NotaryCore/AuthorityRegistry-facing functions ──────────────────────

    /**
     * @notice Collect a specific investment amount from agent's credit balance.
     * Enforces the minimum fee.
     */
    function collectCustomFee(address agent, uint256 amount) external onlyAuthorizedService {
        require(amount >= minFee, "FeeRegistry: amount below minimum fee");
        require(balances[agent] >= amount, "FeeRegistry: insufficient balance");
        
        balances[agent] -= amount;
        escrowedFees    += amount; // Temporary pool until settled

        emit FeeCollected(agent, amount);
    }

    /**
     * @notice Settle collected fees: 90% Burn, 10% Owner.
     */
    function settleFees(uint256 amount) external onlyAuthorizedService returns (uint256 burned) {
        require(escrowedFees >= amount, "FeeRegistry: insufficient fees in escrow");
        
        burned = (amount * 90) / 100;
        uint256 ownerShare = amount - burned;

        escrowedFees     -= amount;
        withdrawableFees += ownerShare;
        totalBurned      += burned;

        // Execute Burn (Transfer to dead address)
        usdc.safeTransfer(address(0x000000000000000000000000000000000000dEaD), burned);

        emit FeeSettled(amount, burned, ownerShare);
        return burned;
    }

    /**
     * @notice Refund a previously collected investment back to the agent's credit balance.
     * Called by NotaryCore when a slot resolves as STATE_DECLINED or STATE_EXPIRED.
     */
    function refundFee(address agent, uint256 amount) external {
        require(msg.sender == notaryCore, "FeeRegistry: only NotaryCore can refund");
        if (amount == 0) return;

        require(escrowedFees >= amount, "FeeRegistry: insufficient escrowedFees for refund");
        escrowedFees     -= amount;
        balances[agent]  += amount;

        emit FeeRefunded(agent, amount);
    }

    // ── Owner-facing functions ─────────────────────────────────────────────

    /**
     * @notice Withdraw earned fees to owner.
     */
    function ownerWithdraw(address to, uint256 amount) external onlyOwner {
        require(amount <= withdrawableFees, "FeeRegistry: amount exceeds withdrawable fees");
        withdrawableFees -= amount;
        usdc.safeTransfer(to, amount);
        emit OwnerWithdrew(to, amount);
    }
}
