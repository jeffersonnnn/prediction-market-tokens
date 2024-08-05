// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract GovernanceRewards is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    IERC20 public predictionToken;
    
    struct UserRewards {
        uint256 lastClaimTimestamp;
        uint256 accumulatedRewards;
        uint256 votingPower;
        uint256 proposalsCreated;
        uint256 votesParticipated;
    }

    mapping(address => UserRewards) public userRewards;
    
    uint256 public constant REWARD_PERIOD = 7 days;
    uint256 public constant BASE_REWARD_RATE = 100; // 1% of voting power per week
    uint256 public constant PROPOSAL_CREATION_BONUS = 500; // 5% bonus for creating a proposal
    uint256 public constant VOTE_PARTICIPATION_BONUS = 50; // 0.5% bonus for participating in a vote
    uint256 public constant MAX_BONUS_PERCENTAGE = 5000; // 50% max bonus

    uint256 public totalRewardsDistributed;
    uint256 public rewardPool;

    event RewardClaimed(address indexed user, uint256 amount);
    event RewardPoolFunded(uint256 amount);
    event GovernanceParticipationRecorded(address indexed user, bool isProposal, uint256 votingPower);

    constructor(address _predictionToken) {
        predictionToken = IERC20(_predictionToken);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function fundRewardPool(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(predictionToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        rewardPool = rewardPool.add(amount);
        emit RewardPoolFunded(amount);
    }

    function recordGovernanceParticipation(address user, bool isProposal, uint256 votingPower) external onlyRole(GOVERNANCE_ROLE) {
        UserRewards storage rewards = userRewards[user];
        rewards.votingPower = votingPower;
        
        if (isProposal) {
            rewards.proposalsCreated = rewards.proposalsCreated.add(1);
        } else {
            rewards.votesParticipated = rewards.votesParticipated.add(1);
        }

        emit GovernanceParticipationRecorded(user, isProposal, votingPower);
    }

    function calculateRewards(address user) public view returns (uint256) {
        UserRewards storage rewards = userRewards[user];
        if (rewards.lastClaimTimestamp == 0) return 0;

        uint256 timeElapsed = block.timestamp.sub(rewards.lastClaimTimestamp);
        uint256 periods = timeElapsed.div(REWARD_PERIOD);

        if (periods == 0) return rewards.accumulatedRewards;

        uint256 baseReward = rewards.votingPower.mul(BASE_REWARD_RATE).mul(periods).div(10000);
        
        uint256 bonusPercentage = rewards.proposalsCreated.mul(PROPOSAL_CREATION_BONUS)
            .add(rewards.votesParticipated.mul(VOTE_PARTICIPATION_BONUS));
        bonusPercentage = bonusPercentage > MAX_BONUS_PERCENTAGE ? MAX_BONUS_PERCENTAGE : bonusPercentage;

        uint256 totalReward = baseReward.add(baseReward.mul(bonusPercentage).div(10000));
        return rewards.accumulatedRewards.add(totalReward);
    }

    function claimRewards() external nonReentrant {
        uint256 rewardAmount = calculateRewards(msg.sender);
        require(rewardAmount > 0, "No rewards to claim");
        require(rewardPool >= rewardAmount, "Insufficient reward pool");

        UserRewards storage rewards = userRewards[msg.sender];
        rewards.lastClaimTimestamp = block.timestamp;
        rewards.accumulatedRewards = 0;
        rewards.proposalsCreated = 0;
        rewards.votesParticipated = 0;

        rewardPool = rewardPool.sub(rewardAmount);
        totalRewardsDistributed = totalRewardsDistributed.add(rewardAmount);

        require(predictionToken.transfer(msg.sender, rewardAmount), "Reward transfer failed");
        emit RewardClaimed(msg.sender, rewardAmount);
    }

    function getUserRewardsInfo(address user) external view returns (
        uint256 lastClaimTimestamp,
        uint256 accumulatedRewards,
        uint256 votingPower,
        uint256 proposalsCreated,
        uint256 votesParticipated,
        uint256 currentRewards
    ) {
        UserRewards storage rewards = userRewards[user];
        return (
            rewards.lastClaimTimestamp,
            rewards.accumulatedRewards,
            rewards.votingPower,
            rewards.proposalsCreated,
            rewards.votesParticipated,
            calculateRewards(user)
        );
    }
}