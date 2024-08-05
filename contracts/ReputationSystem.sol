// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract ReputationSystem is Ownable {
    using SafeMath for uint256;

    struct UserReputation {
        uint256 liquidityScore;
        uint256 accuracyScore;
        uint256 totalParticipation;
        uint256 lastUpdateTimestamp;
    }

    mapping(address => UserReputation) public userReputations;

    uint256 public constant MAX_REPUTATION_SCORE = 10000; // 100.00%
    uint256 public constant DECAY_PERIOD = 30 days;
    uint256 public constant DECAY_RATE = 50; // 0.50% per day

    event ReputationUpdated(address indexed user, uint256 liquidityScore, uint256 accuracyScore, uint256 totalParticipation);

    function updateReputation(
        address user,
        uint256 liquidityChange,
        uint256 accuracyChange,
        uint256 participationChange
    ) external onlyOwner {
        UserReputation storage reputation = userReputations[user];

        // Apply decay to existing scores
        uint256 timePassed = block.timestamp.sub(reputation.lastUpdateTimestamp);
        uint256 decayFactor = timePassed.div(1 days).mul(DECAY_RATE);

        reputation.liquidityScore = applyDecay(reputation.liquidityScore, decayFactor);
        reputation.accuracyScore = applyDecay(reputation.accuracyScore, decayFactor);

        // Update scores
        reputation.liquidityScore = reputation.liquidityScore.add(liquidityChange).min(MAX_REPUTATION_SCORE);
        reputation.accuracyScore = reputation.accuracyScore.add(accuracyChange).min(MAX_REPUTATION_SCORE);
        reputation.totalParticipation = reputation.totalParticipation.add(participationChange);
        reputation.lastUpdateTimestamp = block.timestamp;

        emit ReputationUpdated(user, reputation.liquidityScore, reputation.accuracyScore, reputation.totalParticipation);
    }

    function applyDecay(uint256 score, uint256 decayFactor) internal pure returns (uint256) {
        return score.mul(MAX_REPUTATION_SCORE.sub(decayFactor)).div(MAX_REPUTATION_SCORE);
    }

    function getReputation(address user) external view returns (uint256 liquidityScore, uint256 accuracyScore, uint256 totalParticipation) {
        UserReputation storage reputation = userReputations[user];
        return (reputation.liquidityScore, reputation.accuracyScore, reputation.totalParticipation);
    }

    function getOverallReputation(address user) external view returns (uint256) {
        UserReputation storage reputation = userReputations[user];
        uint256 weightedScore = reputation.liquidityScore.mul(60).add(reputation.accuracyScore.mul(40));
        return weightedScore.div(100);
    }
}