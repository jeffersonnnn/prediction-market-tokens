// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract ReferralProgram is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    IERC20 public predictionToken;
    address public marketFactory;

    struct Referral {
        address referrer;
        uint256 timestamp;
        uint256 totalRewards;
        uint256 totalVolume;
    }

    struct ReferrerStats {
        uint256 totalReferrals;
        uint256 activeReferrals;
        uint256 totalRewards;
        uint256 lastRewardTimestamp;
        uint256 totalVolume;
        uint256 tier;
    }

    mapping(address => Referral) public referrals;
    mapping(address => ReferrerStats) public referrerStats;
    mapping(address => address[]) public referredUsers;

    uint256 public constant REFERRAL_LEVELS = 3;
    uint256[REFERRAL_LEVELS] public referralRewardRates = [500, 300, 100]; // 5%, 3%, 1%
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant REFERRAL_ACTIVE_PERIOD = 365 days;
    uint256 public constant REWARD_LOCK_PERIOD = 30 days;
    uint256 public constant MIN_ACTIVITY_FOR_REWARD = 5;

    uint256 public constant TIER_1_THRESHOLD = 10000 ether;
    uint256 public constant TIER_2_THRESHOLD = 100000 ether;
    uint256 public constant TIER_3_THRESHOLD = 1000000 ether;

    uint256[3] public tierMultipliers = [100, 150, 200]; // 1x, 1.5x, 2x

    uint256 public constant LEADERBOARD_SIZE = 100;
    address[] public leaderboard;

    uint256 public constant TIME_BONUS_THRESHOLD = 180 days;
    uint256 public constant TIME_BONUS_RATE = 50; // 0.5% bonus

    uint256 public totalReferralVolume;
    uint256 public dynamicRewardRate;
    uint256 public lastRewardRateUpdate;
    uint256 public constant REWARD_RATE_UPDATE_INTERVAL = 1 days;

    event ReferralRegistered(address indexed referrer, address indexed referred);
    event ReferralRewardPaid(address indexed referrer, address indexed referred, uint256 amount, uint256 level);
    event ReferralRewardRateUpdated(uint256 level, uint256 newRate);
    event ReferrerTierUpdated(address indexed referrer, uint256 newTier);
    event LeaderboardUpdated(address[] newLeaderboard);
    event DynamicRewardRateUpdated(uint256 newRate);

    constructor(address _predictionToken, address _marketFactory) {
        predictionToken = IERC20(_predictionToken);
        marketFactory = _marketFactory;
        dynamicRewardRate = 500; // Start with 5% reward rate
        lastRewardRateUpdate = block.timestamp;
    }

    function setReferrer(address referrer) external {
        require(referrer != msg.sender, "Cannot refer yourself");
        require(referrals[msg.sender].referrer == address(0), "Referral already set");
        require(referrals[referrer].timestamp > 0 || referrer == marketFactory, "Invalid referrer");

        referrals[msg.sender] = Referral(referrer, block.timestamp, 0, 0);
        referrerStats[referrer].totalReferrals++;
        referrerStats[referrer].activeReferrals++;
        referredUsers[referrer].push(msg.sender);

        emit ReferralRegistered(referrer, msg.sender);
        _updateLeaderboard(referrer);
    }

    function distributeReferralReward(address user, uint256 amount) external {
        require(msg.sender == marketFactory, "Only MarketFactory can distribute rewards");
        _distributeReferralReward(user, amount);
        _updateReferralVolume(user, amount);
    }

    function _distributeReferralReward(address user, uint256 amount) internal {
        address currentReferrer = referrals[user].referrer;
        uint256 remainingReward = amount;

        for (uint256 i = 0; i < REFERRAL_LEVELS && currentReferrer != address(0); i++) {
            if (currentReferrer == marketFactory) break;

            uint256 levelReward = amount.mul(referralRewardRates[i]).div(BASIS_POINTS);
            if (levelReward > remainingReward) {
                levelReward = remainingReward;
            }

            if (_isReferralActive(user, currentReferrer) && _isReferrerEligibleForReward(currentReferrer)) {
                uint256 tierMultiplier = tierMultipliers[referrerStats[currentReferrer].tier];
                uint256 timeBonus = _calculateTimeBonus(user, currentReferrer);
                uint256 totalReward = levelReward.mul(tierMultiplier).div(100).add(timeBonus);

                referrerStats[currentReferrer].totalRewards = referrerStats[currentReferrer].totalRewards.add(totalReward);
                referrerStats[currentReferrer].lastRewardTimestamp = block.timestamp;
                referrals[user].totalRewards = referrals[user].totalRewards.add(totalReward);
                remainingReward = remainingReward.sub(totalReward);

                emit ReferralRewardPaid(currentReferrer, user, totalReward, i + 1);
            }

            currentReferrer = referrals[currentReferrer].referrer;
        }
    }

    function _updateReferralVolume(address user, uint256 amount) internal {
        referrals[user].totalVolume = referrals[user].totalVolume.add(amount);
        address referrer = referrals[user].referrer;
        if (referrer != address(0)) {
            referrerStats[referrer].totalVolume = referrerStats[referrer].totalVolume.add(amount);
            _updateReferrerTier(referrer);
        }
        totalReferralVolume = totalReferralVolume.add(amount);
    }

    function _updateReferrerTier(address referrer) internal {
        uint256 volume = referrerStats[referrer].totalVolume;
        uint256 newTier;
        if (volume >= TIER_3_THRESHOLD) {
            newTier = 2;
        } else if (volume >= TIER_2_THRESHOLD) {
            newTier = 1;
        } else if (volume >= TIER_1_THRESHOLD) {
            newTier = 0;
        }

        if (newTier != referrerStats[referrer].tier) {
            referrerStats[referrer].tier = newTier;
            emit ReferrerTierUpdated(referrer, newTier);
            _updateLeaderboard(referrer);
        }
    }

    function _calculateTimeBonus(address referred, address referrer) internal view returns (uint256) {
        uint256 referralDuration = block.timestamp.sub(referrals[referred].timestamp);
        if (referralDuration >= TIME_BONUS_THRESHOLD) {
            return referrerStats[referrer].totalRewards.mul(TIME_BONUS_RATE).div(BASIS_POINTS);
        }
        return 0;
    }

    function _updateLeaderboard(address referrer) internal {
        uint256 index = leaderboard.length;
        for (uint256 i = 0; i < leaderboard.length; i++) {
            if (leaderboard[i] == referrer) {
                index = i;
                break;
            }
        }

        if (index == leaderboard.length) {
            if (leaderboard.length < LEADERBOARD_SIZE) {
                leaderboard.push(referrer);
                index = leaderboard.length - 1;
            } else {
                return;
            }
        }

        while (index > 0 && referrerStats[leaderboard[index - 1]].totalVolume < referrerStats[referrer].totalVolume) {
            leaderboard[index] = leaderboard[index - 1];
            index--;
        }
        leaderboard[index] = referrer;

        emit LeaderboardUpdated(leaderboard);
    }

    function claimReferralRewards() external nonReentrant {
        ReferrerStats storage stats = referrerStats[msg.sender];
        require(stats.totalRewards > 0, "No rewards to claim");
        require(block.timestamp >= stats.lastRewardTimestamp.add(REWARD_LOCK_PERIOD), "Reward lock period not over");

        uint256 rewardsToClaim = stats.totalRewards;
        stats.totalRewards = 0;
        stats.lastRewardTimestamp = block.timestamp;

        require(predictionToken.transfer(msg.sender, rewardsToClaim), "Reward transfer failed");
    }

    function updateReferralRewardRate(uint256 level, uint256 newRate) external onlyOwner {
        require(level > 0 && level <= REFERRAL_LEVELS, "Invalid level");
        require(newRate <= 1000, "Rate too high"); // Max 10%
        referralRewardRates[level - 1] = newRate;
        emit ReferralRewardRateUpdated(level, newRate);
    }

    function _isReferralActive(address referred, address referrer) internal view returns (bool) {
        return block.timestamp <= referrals[referred].timestamp.add(REFERRAL_ACTIVE_PERIOD);
    }

    function _isReferrerEligibleForReward(address referrer) internal view returns (bool) {
        return referrerStats[referrer].activeReferrals >= MIN_ACTIVITY_FOR_REWARD;
    }

    function getReferralInfo(address user) external view returns (address referrer, uint256 timestamp, uint256 totalRewards, uint256 totalVolume) {
        Referral memory referral = referrals[user];
        return (referral.referrer, referral.timestamp, referral.totalRewards, referral.totalVolume);
    }

    function getReferrerStats(address referrer) external view returns (
        uint256 totalReferrals,
        uint256 activeReferrals,
        uint256 totalRewards,
        uint256 lastRewardTimestamp,
        uint256 totalVolume,
        uint256 tier
    ) {
        ReferrerStats memory stats = referrerStats[referrer];
        return (
            stats.totalReferrals,
            stats.activeReferrals,
            stats.totalRewards,
            stats.lastRewardTimestamp,
            stats.totalVolume,
            stats.tier
        );
    }

    function getReferredUsers(address referrer) external view returns (address[] memory) {
        return referredUsers[referrer];
    }

    function getLeaderboard() external view returns (address[] memory) {
        return leaderboard;
    }

    function updateDynamicRewardRate() external {
        require(block.timestamp >= lastRewardRateUpdate.add(REWARD_RATE_UPDATE_INTERVAL), "Too soon to update");
        
        uint256 dailyVolume = totalReferralVolume.div(REWARD_RATE_UPDATE_INTERVAL);
        uint256 newRate;

        if (dailyVolume < 1000 ether) {
            newRate = 300; // 3%
        } else if (dailyVolume < 10000 ether) {
            newRate = 400; // 4%
        } else if (dailyVolume < 100000 ether) {
            newRate = 500; // 5%
        } else {
            newRate = 600; // 6%
        }

        dynamicRewardRate = newRate;
        lastRewardRateUpdate = block.timestamp;
        emit DynamicRewardRateUpdated(newRate);
    }

    function getDynamicRewardRate() external view returns (uint256) {
        return dynamicRewardRate;
    }
}