// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracle {
    event MarketOutcomeRequested(uint256 indexed marketId, bytes32 indexed requestId);
    event MarketOutcomeReceived(uint256 indexed marketId, bytes32 indexed requestId, uint256 outcome);
    event DisputeRaised(bytes32 indexed requestId, address indexed disputer);
    event DisputeResolved(bytes32 indexed requestId, uint256 finalOutcome);

    function requestMarketOutcome(uint256 marketId) external returns (bytes32 requestId);
    function fulfillMarketOutcome(bytes32 requestId, uint256 outcome) external;
    function getMarketOutcome(bytes32 requestId) external view returns (bool fulfilled, uint256 outcome);
    function disputeOutcome(bytes32 requestId) external payable;
    function resolveDispute(bytes32 requestId, uint256 finalOutcome) external;
    function getDisputeStatus(bytes32 requestId) external view returns (bool isDisputed, uint256 disputeEndTime);
}