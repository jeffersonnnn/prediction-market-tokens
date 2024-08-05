// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract RobustOracle is IOracle, AccessControl, Pausable {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant DISPUTE_RESOLVER_ROLE = keccak256("DISPUTE_RESOLVER_ROLE");

    uint256 public constant DISPUTE_PERIOD = 2 days;
    uint256 public constant DISPUTE_FEE = 100 ether; // Adjust as needed

    struct OutcomeData {
        bool fulfilled;
        uint256 outcome;
        bool disputed;
        uint256 disputeEndTime;
    }

    mapping(bytes32 => OutcomeData) public outcomes;

    event DisputeRaised(bytes32 indexed requestId, address disputer);
    event DisputeResolved(bytes32 indexed requestId, uint256 finalOutcome);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        _grantRole(DISPUTE_RESOLVER_ROLE, msg.sender);
    }

    function requestMarketOutcome(uint256 marketId) external override returns (bytes32) {
        bytes32 requestId = keccak256(abi.encodePacked(marketId, block.timestamp));
        emit MarketOutcomeRequested(marketId, requestId);
        return requestId;
    }

    function fulfillMarketOutcome(bytes32 requestId, uint256 outcome) external override onlyRole(ORACLE_ROLE) {
        require(!outcomes[requestId].fulfilled, "Outcome already fulfilled");
        outcomes[requestId] = OutcomeData(true, outcome, false, 0);
        emit MarketOutcomeFulfilled(requestId, outcome);
    }

    function getMarketOutcome(bytes32 requestId) external view override returns (bool fulfilled, uint256 outcome) {
        OutcomeData memory data = outcomes[requestId];
        return (data.fulfilled && !data.disputed, data.outcome);
    }

    function disputeOutcome(bytes32 requestId) external payable {
        require(msg.value >= DISPUTE_FEE, "Insufficient dispute fee");
        require(outcomes[requestId].fulfilled, "Outcome not yet fulfilled");
        require(!outcomes[requestId].disputed, "Outcome already disputed");
        require(block.timestamp <= outcomes[requestId].disputeEndTime, "Dispute period ended");

        outcomes[requestId].disputed = true;
        outcomes[requestId].disputeEndTime = block.timestamp + DISPUTE_PERIOD;

        emit DisputeRaised(requestId, msg.sender);
    }

    function resolveDispute(bytes32 requestId, uint256 finalOutcome) external onlyRole(DISPUTE_RESOLVER_ROLE) {
        require(outcomes[requestId].disputed, "No active dispute");
        require(block.timestamp > outcomes[requestId].disputeEndTime, "Dispute period not ended");

        outcomes[requestId].outcome = finalOutcome;
        outcomes[requestId].disputed = false;

        emit DisputeResolved(requestId, finalOutcome);
    }

    function getDisputeStatus(bytes32 requestId) external view returns (bool isDisputed, uint256 disputeEndTime) {
        OutcomeData memory data = outcomes[requestId];
        return (data.disputed, data.disputeEndTime);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}