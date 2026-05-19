// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IFeeRegistry {
    function currentSubmissionFee() external view returns (uint256);
    function currentRegistrationFee() external view returns (uint256);

    /// @notice Collect fee from agent's pre-deposited credit balance.
    /// Called by NotaryCore or AuthorityRegistry.
    function collectFee(address agent) external;

    /// @notice Collect a specific fee amount.
    function collectCustomFee(address agent, uint256 amount) external;

    /// @notice Settle collected fees (90% Burn, 10% Owner).
    function settleFees(uint256 amount) external returns (uint256 burned);

    /// @notice Refund a previously collected fee back to agent's credit balance.
    /// Called by NotaryCore when a slot resolves as DECLINED or EXPIRED,
    /// since the submitter did not receive a service (no badge was issued).
    /// Only callable by NotaryCore.
    function refundFee(address agent, uint256 amount) external;
}
