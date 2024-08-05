// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./interfaces/IExternalStakingProtocol.sol";

contract ExternalStakingManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    IERC20 public predictionToken;
    Treasury public treasury;

    struct StakingProtocol {
        IExternalStakingProtocol protocol;
        bool isActive;
        uint256 totalStaked;
        uint256 rewardMultiplier;
    }

    struct UserStake {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastUpdateTime;
    }

    mapping(address => StakingProtocol) public stakingProtocols;
    mapping(address => mapping(address => UserStake)) public userStakes;
    address[] public activeProtocols;

    uint256 public constant REWARD_PRECISION = 1e12;
    uint256 public totalAllocPoint;
    uint256 public rewardPerSecond;
    uint256 public lastRewardTime;

    event ProtocolAdded(address indexed protocolAddress, uint256 rewardMultiplier);
    event ProtocolUpdated(address indexed protocolAddress, uint256 rewardMultiplier, bool isActive);
    event Staked(address indexed user, address indexed protocol, uint256 amount);
    event Unstaked(address indexed user, address indexed protocol, uint256 amount);
    event RewardClaimed(address indexed user, address indexed protocol, uint256 amount);
    event RewardRateUpdated(uint256 newRewardPerSecond);

    constructor(address _predictionToken, address _treasury) {
        predictionToken = IERC20(_predictionToken);
        treasury = Treasury(_treasury);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(GOVERNANCE_ROLE, msg.sender);
    }

    function addStakingProtocol(address _protocolAddress, uint256 _rewardMultiplier) external onlyRole(GOVERNANCE_ROLE) {
        require(_protocolAddress != address(0), "Invalid protocol address");
        require(!stakingProtocols[_protocolAddress].isActive, "Protocol already active");

        stakingProtocols[_protocolAddress] = StakingProtocol({
            protocol: IExternalStakingProtocol(_protocolAddress),
            isActive: true,
            totalStaked: 0,
            rewardMultiplier: _rewardMultiplier
        });

        activeProtocols.push(_protocolAddress);
        totalAllocPoint = totalAllocPoint.add(_rewardMultiplier);

        emit ProtocolAdded(_protocolAddress, _rewardMultiplier);
    }

    function updateStakingProtocol(address _protocolAddress, uint256 _rewardMultiplier, bool _isActive) external onlyRole(GOVERNANCE_ROLE) {
        require(stakingProtocols[_protocolAddress].isActive, "Protocol not active");

        StakingProtocol storage protocol = stakingProtocols[_protocolAddress];
        totalAllocPoint = totalAllocPoint.sub(protocol.rewardMultiplier).add(_rewardMultiplier);

        protocol.rewardMultiplier = _rewardMultiplier;
        protocol.isActive = _isActive;

        if (!_isActive) {
            for (uint256 i = 0; i < activeProtocols.length; i++) {
                if (activeProtocols[i] == _protocolAddress) {
                    activeProtocols[i] = activeProtocols[activeProtocols.length - 1];
                    activeProtocols.pop();
                    break;
                }
            }
        }

        emit ProtocolUpdated(_protocolAddress, _rewardMultiplier, _isActive);
    }

    function stake(address _protocolAddress, uint256 _amount) external nonReentrant {
        StakingProtocol storage protocol = stakingProtocols[_protocolAddress];
        require(protocol.isActive, "Protocol not active");
        require(_amount > 0, "Amount must be greater than 0");

        updateRewards(_protocolAddress);

        UserStake storage userStake = userStakes[msg.sender][_protocolAddress];
        if (userStake.amount > 0) {
            uint256 pending = userStake.amount.mul(protocol.protocol.accRewardPerShare().sub(userStake.rewardDebt)).div(REWARD_PRECISION);
            if (pending > 0) {
                safeRewardTransfer(msg.sender, pending);
            }
        }

        predictionToken.safeTransferFrom(msg.sender, address(this), _amount);
        predictionToken.safeApprove(_protocolAddress, _amount);
        protocol.protocol.stake(_amount);

        userStake.amount = userStake.amount.add(_amount);
        userStake.rewardDebt = userStake.amount.mul(protocol.protocol.accRewardPerShare()).div(REWARD_PRECISION);
        userStake.lastUpdateTime = block.timestamp;

        protocol.totalStaked = protocol.totalStaked.add(_amount);

        emit Staked(msg.sender, _protocolAddress, _amount);
    }

    function unstake(address _protocolAddress, uint256 _amount) external nonReentrant {
        StakingProtocol storage protocol = stakingProtocols[_protocolAddress];
        UserStake storage userStake = userStakes[msg.sender][_protocolAddress];
        require(userStake.amount >= _amount, "Insufficient staked amount");

        updateRewards(_protocolAddress);

        uint256 pending = userStake.amount.mul(protocol.protocol.accRewardPerShare().sub(userStake.rewardDebt)).div(REWARD_PRECISION);
        if (pending > 0) {
            safeRewardTransfer(msg.sender, pending);
        }

        if (_amount > 0) {
            userStake.amount = userStake.amount.sub(_amount);
            protocol.protocol.unstake(_amount);
            predictionToken.safeTransfer(msg.sender, _amount);
            protocol.totalStaked = protocol.totalStaked.sub(_amount);
        }

        userStake.rewardDebt = userStake.amount.mul(protocol.protocol.accRewardPerShare()).div(REWARD_PRECISION);
        userStake.lastUpdateTime = block.timestamp;

        emit Unstaked(msg.sender, _protocolAddress, _amount);
    }

    function claimRewards(address _protocolAddress) external nonReentrant {
        updateRewards(_protocolAddress);

        StakingProtocol storage protocol = stakingProtocols[_protocolAddress];
        UserStake storage userStake = userStakes[msg.sender][_protocolAddress];

        uint256 pending = userStake.amount.mul(protocol.protocol.accRewardPerShare().sub(userStake.rewardDebt)).div(REWARD_PRECISION);
        if (pending > 0) {
            safeRewardTransfer(msg.sender, pending);
        }

        userStake.rewardDebt = userStake.amount.mul(protocol.protocol.accRewardPerShare()).div(REWARD_PRECISION);
        userStake.lastUpdateTime = block.timestamp;

        emit RewardClaimed(msg.sender, _protocolAddress, pending);
    }

    function updateRewards(address _protocolAddress) public {
        StakingProtocol storage protocol = stakingProtocols[_protocolAddress];
        if (block.timestamp <= lastRewardTime) {
            return;
        }

        if (protocol.totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        uint256 multiplier = block.timestamp.sub(lastRewardTime);
        uint256 reward = multiplier.mul(rewardPerSecond).mul(protocol.rewardMultiplier).div(totalAllocPoint);
        protocol.protocol.updateRewards(reward);

        lastRewardTime = block.timestamp;
    }

    function setRewardRate(uint256 _rewardPerSecond) external onlyRole(GOVERNANCE_ROLE) {
        updateAllRewards();
        rewardPerSecond = _rewardPerSecond;
        emit RewardRateUpdated(_rewardPerSecond);
    }

    function updateAllRewards() public {
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            updateRewards(activeProtocols[i]);
        }
    }

    function safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 rewardBalance = predictionToken.balanceOf(address(this));
        if (_amount > rewardBalance) {
            predictionToken.safeTransfer(_to, rewardBalance);
        } else {
            predictionToken.safeTransfer(_to, _amount);
        }
    }

    function getProtocolInfo(address _protocolAddress) external view returns (bool isActive, uint256 totalStaked, uint256 rewardMultiplier, uint256 accRewardPerShare) {
        StakingProtocol storage protocol = stakingProtocols[_protocolAddress];
        return (protocol.isActive, protocol.totalStaked, protocol.rewardMultiplier, protocol.protocol.accRewardPerShare());
    }

    function getUserStakeInfo(address _user, address _protocolAddress) external view returns (uint256 amount, uint256 rewardDebt, uint256 lastUpdateTime, uint256 pendingRewards) {
        UserStake storage userStake = userStakes[_user][_protocolAddress];
        StakingProtocol storage protocol = stakingProtocols[_protocolAddress];

        pendingRewards = userStake.amount.mul(protocol.protocol.accRewardPerShare().sub(userStake.rewardDebt)).div(REWARD_PRECISION);
        return (userStake.amount, userStake.rewardDebt, userStake.lastUpdateTime, pendingRewards);
    }

    function getActiveProtocols() external view returns (address[] memory) {
        return activeProtocols;
    }

    function emergencyWithdraw(address _protocolAddress) external nonReentrant {
        StakingProtocol storage protocol = stakingProtocols[_protocolAddress];
        UserStake storage userStake = userStakes[msg.sender][_protocolAddress];
        uint256 amount = userStake.amount;
        userStake.amount = 0;
        userStake.rewardDebt = 0;

        protocol.protocol.emergencyUnstake(amount);
        predictionToken.safeTransfer(msg.sender, amount);
        protocol.totalStaked = protocol.totalStaked.sub(amount);

        emit Unstaked(msg.sender, _protocolAddress, amount);
    }
}