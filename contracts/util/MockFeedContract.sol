// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// i didn't fully understand the difference between answeredinround and roundID, can't read into chailink docs further tn
contract MockFeedContract is AggregatorV3Interface {
    uint8 private savedDecimals;
    string private savedDescription;
    uint256 private savedVersion;
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        bool exists;
    }

    mapping(uint80 => Round) private _rounds;

    uint80 private currRound;

    function decimals() public view returns (uint8 dec) {
        return savedDecimals;
    }

    function description() public view returns (string memory desc) {
        return savedDescription;
    }

    function version() public view returns (uint256 v) {
        return savedVersion;
    }

    function setRound(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 endedAt
    ) external {
        _rounds[roundId] = Round(answer, startedAt, endedAt, true);
        currRound = roundId;
    }

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function getRoundData(
        uint80 _roundId
    )
        public
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        Round memory round = _rounds[_roundId];
        require(round.exists);
        return (
            _roundId,
            round.answer,
            round.startedAt,
            round.updatedAt,
            currRound
        );
    }

    function latestRoundData()
        public
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        Round memory round = _rounds[currRound];
        require(round.exists);
        return (
            currRound,
            round.answer,
            round.startedAt,
            round.updatedAt,
            currRound
        );
    }
}
