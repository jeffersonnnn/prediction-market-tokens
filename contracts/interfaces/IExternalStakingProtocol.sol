// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExternalStakingProtocol {
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function updateRewards(uint256 reward) external;
    function accRewardPerShare() external view returns (uint256);
    function emergencyUnstake(uint256 amount) external;
}