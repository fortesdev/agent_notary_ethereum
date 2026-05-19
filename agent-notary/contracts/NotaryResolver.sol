// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { SchemaResolver } from "@ethereum-attestation-service/eas-contracts/contracts/resolver/SchemaResolver.sol";
import { IEAS, Attestation } from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NotaryResolver
 * @notice EAS resolver that restricts attestation creation to NotaryCore only.
 *         Revocation is permanently blocked — all badges are immutable.
 */
contract NotaryResolver is SchemaResolver, Ownable {
    address public notaryCore;

    constructor(IEAS eas, address _notaryCore, address _initialOwner) SchemaResolver(eas) {
        notaryCore = _notaryCore;
        _transferOwnership(_initialOwner);
    }

    function setNotaryCore(address _notaryCore) external onlyOwner {
        notaryCore = _notaryCore;
    }

    /// @notice Only NotaryCore may create attestations under these schemas.
    function onAttest(
        Attestation calldata attestation,
        uint256 /*value*/
    ) internal override returns (bool) {
        return attestation.attester == notaryCore;
    }

    /// @notice Revocation permanently blocked — badges are immutable.
    function onRevoke(
        Attestation calldata,
        uint256
    ) internal override returns (bool) {
        return false;
    }
}
