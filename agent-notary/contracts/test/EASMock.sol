// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@ethereum-attestation-service/eas-contracts/contracts/SchemaRegistry.sol";
import "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";

contract EASMock is EAS {
    constructor(ISchemaRegistry _schemaRegistry) EAS(_schemaRegistry) {}
}
