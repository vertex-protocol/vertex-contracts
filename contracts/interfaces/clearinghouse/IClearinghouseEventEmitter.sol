// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IClearinghouseEventEmitter {
    /// @notice Emitted during initialization
    event ClearinghouseInitialized(
        address endpoint,
        address quote,
        address fees
    );

    /// @notice Emitted when a new subaccount is created for an address
    /// @param owner The owner of the subaccount
    /// @param subaccount The new subaccount ID
    event CreateSubaccount(address owner, string name, uint64 subaccount);

    /// @notice Emitted when collateral is modified for a subaccount
    event ModifyCollateral(
        int256 amount,
        uint64 indexed subaccount,
        uint32 productId
    );

    event Liquidation(
        uint64 indexed liquidatorSubaccount,
        uint64 indexed liquidateeSubaccount,
        uint8 indexed mode,
        uint32 healthGroup,
        int256 amountX18,
        int256 amountQuoteX18,
        int256 insuranceCoverX18
    );
}
