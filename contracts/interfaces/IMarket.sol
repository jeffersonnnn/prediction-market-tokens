// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMarket {
    enum Phase { Active, Locked, Resolution, Settled }

    function getMarketInfo() external view returns (
        string memory name,
        uint256 endTime,
        Phase currentPhase,
        uint256 liquidityPool,
        uint256 protocolFees,
        uint256 winningOutcomeIndex,
        uint256[] memory outcomePrices
    );

    function trade(uint256 outcomeIndex, uint256 amount, uint256 maxSlippage, bool isBuy) external;
    function commitTrade(bytes32 commitment) external;
    function revealTrade(uint256 outcomeIndex, uint256 amount, uint256 maxSlippage, bool isBuy, uint256 minTimestamp, uint256 maxTimestamp, uint256 nonce, bytes memory signature) external;
    function addLiquidity(uint256 amount) external;
    function removeLiquidity(uint256 lpTokens) external;
    function claimWinnings() external;
    function claimRewards() external;
    function getCurrentPrice(uint256 outcomeIndex) external view returns (uint256);
    function getTWAP(uint256 outcomeIndex) external view returns (uint256);
    function getPredictorStats(address predictor) external view returns (uint256 totalPredictions, uint256 correctPredictions, uint256 totalStaked, uint256 streak, uint256 highestStreak, uint256 accuracy);
}

interface ITokenInteraction {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IOracle {
    function requestMarketOutcome(uint256 marketId) external returns (bytes32 requestId);
    function fulfillMarketOutcome(bytes32 requestId, uint256 outcome) external;
    function getLatestPrice(address asset) external view returns (uint256);
}

interface ILiquidityProvider {
    function getLiquidityProviderInfo(address provider) external view returns (
        uint256 liquidity,
        uint256 lastUpdateTime,
        uint256 accumulatedRewards,
        uint256 tierIndex,
        uint256 entryPrice
    );
    function calculateILProtection(address provider, uint256 liquidityToRemove) external view returns (uint256);
    function updateProviderTier(address provider) external;
}

interface IGovernance {
    function propose(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) external returns (uint256);
    function castVote(uint256 proposalId, uint8 support) external;
    function execute(uint256 proposalId) external;
    function getProposalState(uint256 proposalId) external view returns (uint8);
    function getVotes(address account) external view returns (uint256);
}

interface IReputationSystem {
    function updateReputation(address user, uint256 liquidityChange, uint256 accuracyChange, uint256 participation) external;
    function getReputation(address user) external view returns (uint256 liquidityScore, uint256 accuracyScore, uint256 totalParticipation);
    function getOverallReputation(address user) external view returns (uint256);
}

interface IIncentiveManager {
    function updateMetricHistory(uint256 volume, uint256 volatility) external;
    function getLiquidityIncentiveRate() external view returns (uint256);
    function getTradeIncentiveRate() external view returns (uint256);
    function distributeIncentives(address user, uint256 amount, bool isLiquidity) external;
}

interface ICrossChainBridge {
    function bridgeAsset(uint256 chainId, address recipient, uint256 amount) external;
    function claimBridgedAsset(uint256 sourceChainId, bytes memory proof) external;
    function verifyBridgeTransaction(uint256 sourceChainId, bytes memory proof) external view returns (bool);
}

interface IMarketFactory {
    function createMarket(string memory name, uint256 endTime, string[] memory outcomeNames, address oracleAddress, uint256 initialLiquidity) external returns (address);
    function getMarkets() external view returns (address[] memory);
    function setMarketCreationFee(uint256 newFee) external;
    function setFeeRecipient(address newRecipient) external;
}

interface IReferralProgram {
    function registerReferrer(address referrer) external;
    function getReferralInfo(address user) external view returns (address referrer, uint256 totalRewards);
    function distributeReferralReward(address user, uint256 amount) external;
}

interface IExternalStakingManager {
    function stake(address protocolAddress, uint256 amount) external;
    function unstake(address protocolAddress, uint256 amount) external;
    function claimRewards(address protocolAddress) external;
    function getStakedAmount(address user, address protocolAddress) external view returns (uint256);
    function getPendingRewards(address user, address protocolAddress) external view returns (uint256);
}