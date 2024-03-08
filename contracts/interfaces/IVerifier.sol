// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IVerifier {
    function requireValidSignature(
        bytes32 message,
        bytes32 e,
        bytes32 s,
        uint8 signerBitmask
    ) external;

    function revertGasInfo(uint256 i, uint256 gasUsed) external pure;
}
