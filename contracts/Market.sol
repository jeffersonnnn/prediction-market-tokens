// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./OutcomeToken.sol";
import "./LPToken.sol";
import "./IOracle.sol";
import "./Treasury.sol";
import "./GovernanceRewards.sol";

import "./IMarket.sol";
import "./ITokenInteraction.sol";
import "./ILiquidityProvider.sol";
import "./IReputationSystem.sol";
import "./IIncentiveManager.sol";

contract Market is IMarket, ITokenInteraction, ILiquidityProvider, Ownable, ReentrancyGuard {
    using Math for uint256;
    using ECDSA for bytes32;

    string public name;
    uint256 public immutable endTime;
    IERC20 public immutable predictionToken;
    LPToken public immutable lpToken;
    IOracle public oracle;
    Treasury public immutable treasury;
    DynamicIncentiveManager public incentiveManager;
    ReputationSystem public reputationSystem;
    GovernanceRewards public governanceRewards;
    ReferralProgram public referralProgram;

    enum Phase {
        Active,
        Locked,
        Resolution,
        Settled
    }
    Phase public currentPhase;

    OutcomeToken[] public outcomeTokens;
    uint256 public FEE;
    uint256 public constant FEE_DENOMINATOR = 10000;

    uint256 public liquidityPool;
    uint256 public protocolFees;
    uint256 public winningOutcomeIndex;
    bytes32 public oracleRequestId;

    uint256 public constant BASE_FEE = 30; // 0.3% base fee
    uint256 public constant MAX_FEE = 100; // 1% max fee
    uint256 public constant VOLATILITY_PERIOD = 1 hours;
    uint256 public lastTradeTimestamp;
    uint256 public cumulativeVolatility;

    uint256 public constant MAX_SLIPPAGE = 1000; // 10% maximum allowed slippage
    uint256 public constant MAX_PRICE_IMPACT = 500; // 5% maximum allowed price impact
    uint256 public constant PRICE_IMPACT_WINDOW = 5 minutes;

    uint256 public constant CURVE_FACTOR = 1e18; // Curve steepness factor
    uint256 public constant MIN_PRICE = 1e15; // Minimum price (0.001)
    uint256 public constant MAX_PRICE = 999e15; // Maximum price (0.999)
    uint256 public constant COMMIT_REVEAL_DEADLINE = 5 minutes;
    uint256 public constant MAX_MEV_PROTECTION = 100; // 1% maximum MEV protection

    uint256 public constant REWARD_PERIOD = 1 days;
    uint256 public constant BASE_REWARD_RATE = 1e15; // 0.1% per day
    uint256 public constant MAX_IL_PROTECTION = 5000; // 50% max IL protection
    uint256 public constant IL_PROTECTION_PERIOD = 30 days;
    uint256 public constant TWAP_PERIOD = 1 hours;
    uint256 public constant MAX_OBSERVATIONS = 24;

    mapping(bytes32 => CommitData) public commitments;

    LiquidityTier[] public liquidityTiers;
    mapping(address => LiquidityProvider) public liquidityProviders;

    struct LiquidityTier {
        uint256 minLiquidity;
        uint256 rewardMultiplier;
    }

    struct LiquidityProvider {
        uint256 liquidity;
        uint256 lastUpdateTime;
        uint256 accumulatedRewards;
        uint256 tierIndex;
        uint256 entryPrice;
    }

    struct TWAPObservation {
        uint256 timestamp;
        uint256 price;
    }

    mapping(uint256 => TWAPObservation[]) public twapObservations;

    struct CircularBuffer {
        uint256[] values;
        uint256 sum;
        uint256 index;
        uint256 count;
    }

    struct CommitData {
        address trader;
        uint256 commitTime;
        bool revealed;
    }

    struct TradeIntent {
        uint256 outcomeIndex;
        uint256 amount;
        uint256 maxSlippage;
        bool isBuy;
        uint256 minTimestamp;
        uint256 maxTimestamp;
        uint256 nonce;
    }

    struct PredictorStats {
        uint256 totalPredictions;
        uint256 correctPredictions;
        uint256 totalStaked;
        uint256 lastPredictionTimestamp;
        uint256 streak;
        uint256 highestStreak;
    }

    mapping(uint256 => CircularBuffer) private priceImpactHistory;
    mapping(address => PredictorStats) public predictorStats;
    uint256 public constant EARLY_PREDICTOR_THRESHOLD = 7 days;
    uint256 public constant ACCURACY_REWARD_RATE = 100; // 1% of stake
    uint256 public constant EARLY_PREDICTOR_BONUS = 50; // 0.5% bonus
    uint256 public constant STREAK_BONUS_RATE = 10; // 0.1% per streak
    uint256 public constant MAX_STREAK_BONUS = 500; // 5% max streak bonus

    // Events
    event PositionTaken(
        address indexed trader,
        uint256 outcomeIndex,
        uint256 amount,
        uint256 outputAmount,
        uint256 priceImpact,
        uint256 slippage,
        uint256 mevProtection,
        uint256 nonce
    );

    event LiquidityAdded(address indexed provider, uint256 amount);
    event LiquidityRemoved(address indexed provider, uint256 amount);
    event MarketResolved(uint256 winningOutcomeIndex);
    event PhaseSwitched(Phase newPhase);
    event WinningsClaimed(address indexed trader, uint256 amount);
    event FeeDistributed(address indexed recipient, uint256 amount);
    event MarketResolutionRequested(bytes32 indexed requestId);
    event MarketResolutionFulfilled(uint256 winningOutcomeIndex);
    event OracleUpdated(address newOracleAddress);
    event TradeCommitted(address indexed trader, bytes32 indexed commitment);
    event TradeRevealed(address indexed trader, bytes32 indexed commitment, uint256 outcomeIndex, uint256 amount, bool isBuy);
    event LiquidityChanged(uint256 newLiquidityPool, uint256[] newOutcomeReserves);
    event FeeUpdated(uint256 newFee);
    event TWAPUpdated(uint256 indexed outcomeIndex, uint256 newTWAP);
    event PriceImpactRecorded(uint256 indexed outcomeIndex, uint256 priceImpact, uint256 averagePriceImpact);
    event LiquidityAdded(address indexed provider, uint256 amount, uint256 lpTokens);
    event LiquidityRemoved(address indexed provider, uint256 amount, uint256 lpTokens, uint256 ilProtection);
    event RewardsClaimed(address indexed provider, uint256 amount);
    event RewardDistributed(address indexed predictor, uint256 amount);
    event PredictionRecorded(address indexed predictor, uint256 outcomeIndex, uint256 amount);
    event StreakUpdated(address indexed predictor, uint256 newStreak, uint256 highestStreak);

    modifier onlyActivePhase() {
        require(currentPhase == Phase.Active, "Market not active");
        _;
    }

    modifier onlyBeforeEndTime() {
        require(block.timestamp < endTime, "Market has ended");
        _;
    }

    constructor(
        string memory _name,
        uint256 _endTime,
        address _predictionTokenAddress,
        string[] memory _outcomeNames,
        address _oracleAddress,
        address _treasuryAddress
    ) Ownable(msg.sender) {
        require(_endTime > block.timestamp, "End time must be in the future");
        require(_outcomeNames.length >= 2, "At least two outcomes required");
        require(
            _predictionTokenAddress != address(0),
            "Invalid prediction token address"
        );
        require(_oracleAddress != address(0), "Invalid oracle address");
        require(_treasuryAddress != address(0), "Invalid treasury address");

           // Initialize liquidity tiers
        liquidityTiers.push(LiquidityTier(1000 * 1e18, 100));  // 1,000 tokens, 1x multiplier
        liquidityTiers.push(LiquidityTier(10000 * 1e18, 125)); // 10,000 tokens, 1.25x multiplier
        liquidityTiers.push(LiquidityTier(100000 * 1e18, 150)); // 100,000 tokens, 1.5x multiplier

        name = _name;
        endTime = _endTime;
        predictionToken = IERC20(_predictionTokenAddress);
        treasury = Treasury(_treasuryAddress);
        oracle = IOracle(_oracleAddress);
        currentPhase = Phase.Active;
        FEE = BASE_FEE;

        for (uint256 i = 0; i < _outcomeNames.length; i++) {
            OutcomeToken newToken = new OutcomeToken(
                _outcomeNames[i],
                _outcomeNames[i],
                address(this)
            );
            outcomeTokens.push(newToken);
        }

        lpToken = new LPToken("LP Token", "LPT", address(this));
        lastTradeTimestamp = block.timestamp;
        incentiveManager = new DynamicIncentiveManager(address(this), address(predictionToken));
        transferOwnership(address(incentiveManager));
        reputationSystem = new ReputationSystem();
        referralProgram = ReferralProgram(address(treasury.referralProgram()));
    }


    function commitTrade(bytes32 commitment) external {
        require(commitments[commitment].trader == address(0), "Commitment already exists");
        commitments[commitment] = CommitData(msg.sender, block.timestamp, false);
        emit TradeCommitted(msg.sender, commitment);
    }

    function revealTrade(
        uint256 outcomeIndex,
        uint256 amount,
        uint256 maxSlippage,
        bool isBuy,
        uint256 minTimestamp,
        uint256 maxTimestamp,
        uint256 nonce,
        bytes memory signature
    ) external onlyActivePhase onlyBeforeEndTime nonReentrant {
        bytes32 commitment = keccak256(abi.encode(
            msg.sender, outcomeIndex, amount, maxSlippage, isBuy, minTimestamp, maxTimestamp, nonce
        ));
        CommitData storage commitData = commitments[commitment];
        require(commitData.trader == msg.sender, "Invalid commitment");
        require(!commitData.revealed, "Already revealed");
        require(block.timestamp >= commitData.commitTime + COMMIT_REVEAL_DEADLINE, "Reveal too early");
        require(block.timestamp >= minTimestamp && block.timestamp <= maxTimestamp, "Invalid timestamp");

        bytes32 messageHash = keccak256(abi.encodePacked(commitment, address(this)));
        require(messageHash.toEthSignedMessageHash().recover(signature) == msg.sender, "Invalid signature");

        commitData.revealed = true;
        executeTrade(TradeIntent(outcomeIndex, amount, maxSlippage, isBuy, minTimestamp, maxTimestamp, nonce));
        emit TradeRevealed(msg.sender, commitment, outcomeIndex, amount, isBuy);
    }

    function executeTrade(TradeIntent memory intent) internal {
        require(intent.outcomeIndex < outcomeTokens.length, "Invalid outcome");
        require(intent.amount > 0, "Amount must be greater than 0");
        require(intent.maxSlippage <= MAX_SLIPPAGE, "Slippage tolerance too high");

        calculateDynamicFee();

        uint256 inputReserve = intent.isBuy ? liquidityPool : outcomeTokens[intent.outcomeIndex].balanceOf(address(this));
        uint256 outputReserve = intent.isBuy ? outcomeTokens[intent.outcomeIndex].balanceOf(address(this)) : liquidityPool;

        uint256 inputAmountWithFee = intent.amount * (FEE_DENOMINATOR - FEE);
        (uint256 outputAmount, uint256 newPrice) = calculateTradeOutcome(
            inputReserve,
            outputReserve,
            inputAmountWithFee,
            intent.isBuy
        );

        uint256 slippage = calculateSlippage(inputReserve, outputReserve, intent.amount, outputAmount, intent.isBuy);
        require(slippage <= intent.maxSlippage, "Slippage tolerance exceeded");

        uint256 priceImpact = calculatePriceImpact(inputReserve, outputReserve, intent.amount, outputAmount);
        require(priceImpact <= MAX_PRICE_IMPACT, "Price impact too high");

        uint256 averagePriceImpact = getAveragePriceImpact(intent.outcomeIndex);
        require(averagePriceImpact <= MAX_PRICE_IMPACT, "Average price impact too high");

        uint256 mevProtection = calculateMEVProtection(_outcomeIndex, inputAmount, outputAmount);
        outputAmount = outputAmount * (FEE_DENOMINATOR - mevProtection) / FEE_DENOMINATOR;

        performTrade(msg.sender, intent.outcomeIndex, intent.amount, outputAmount, intent.isBuy);

        uint256 feeAmount = intent.amount - (inputAmountWithFee / FEE_DENOMINATOR);
        protocolFees += feeAmount;

        updateTWAP(intent.outcomeIndex, newPrice);
        updatePriceImpactHistory(intent.outcomeIndex, priceImpact);

        emit PositionTaken(
            trader,
            outcomeIndex,
            inputAmount,
            outputAmount,
            priceImpact,
            slippage,
            mevProtection,
            intent.nonce
        );

    uint256 referralReward = (inputAmount * referralProgram.getDynamicRewardRate()) / referralProgram.BASIS_POINTS();
    referralProgram.distributeReferralReward(msg.sender, referralReward);
    }

    function calculateMEVProtection(uint256 inputAmount, uint256 outputAmount) internal view returns (uint256) {
        uint256 expectedPrice = getCurrentPrice(outcomeIndex);
        uint256 actualPrice = (inputAmount * 1e18) / outputAmount;
        uint256 priceDifference = actualPrice > expectedPrice ? actualPrice - expectedPrice : expectedPrice - actualPrice;
        uint256 mevProtection = (priceDifference * MAX_MEV_PROTECTION) / expectedPrice;
        return Math.min(mevProtection, MAX_MEV_PROTECTION);
    }


    function addLiquidity(uint256 _amount) external onlyActivePhase onlyBeforeEndTime nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(predictionToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");

        updateRewards(msg.sender, incentiveManager.getLiquidityIncentiveRate());

        LiquidityProvider storage provider = liquidityProviders[msg.sender];
        provider.liquidity += _amount;
        provider.lastUpdateTime = block.timestamp;
        provider.entryPrice = getCurrentPrice();

        updateProviderTier(msg.sender);

        uint256 lpTokensToMint = calculateLPTokens(_amount);
        lpToken.mint(msg.sender, lpTokensToMint);

        liquidityPool += _amount;

        emit LiquidityAdded(msg.sender, _amount, lpTokensToMint);
        emit LiquidityChanged(liquidityPool, getOutcomeReserves());

        uint256 liquidityChange = (_amount * 100) / liquidityPool;
        reputationSystem.updateReputation(msg.sender, liquidityChange, 0, 1);
    }

    function resolveMarket(uint256 _winningOutcomeIndex) external onlyOwner {
        require(currentPhase == Phase.Resolution, "Not in resolution phase");
        require(_winningOutcomeIndex < outcomeTokens.length, "Invalid winning outcome");

        winningOutcomeIndex = _winningOutcomeIndex;
        currentPhase = Phase.Settled;

        distributeRewards();

        emit MarketResolved(winningOutcomeIndex);
    }

    function getPredictorStats(address predictor) external view returns (
        uint256 totalPredictions,
        uint256 correctPredictions,
        uint256 totalStaked,
        uint256 streak,
        uint256 highestStreak,
        uint256 accuracy
    ) {
        PredictorStats storage stats = predictorStats[predictor];
        totalPredictions = stats.totalPredictions;
        correctPredictions = stats.correctPredictions;
        totalStaked = stats.totalStaked;
        streak = stats.streak;
        highestStreak = stats.highestStreak;
        accuracy = totalPredictions > 0 ? (correctPredictions * 10000) / totalPredictions : 0;
    }

    function updateRewards(address provider, uint256 incentiveRate) internal {
        LiquidityProvider storage lp = liquidityProviders[provider];
        if (lp.liquidity > 0) {
            uint256 timeElapsed = block.timestamp - lp.lastUpdateTime;
            uint256 rewards = (lp.liquidity * incentiveRate * timeElapsed * liquidityTiers[lp.tierIndex].rewardMultiplier) / (REWARD_PERIOD * 10000);
            lp.accumulatedRewards += rewards;
            lp.lastUpdateTime = block.timestamp;
        }
    }

    function updateMarketMetrics(uint256 volume, uint256 volatility) external {
        require(msg.sender == address(incentiveManager), "Only incentive manager can update metrics");
        incentiveManager.updateMetricHistory(volume, volatility);
    }

    function removeLiquidity(uint256 _lpTokens) external nonReentrant {
        require(_lpTokens > 0, "Amount must be greater than 0");
        require(lpToken.balanceOf(msg.sender) >= _lpTokens, "Insufficient LP tokens");

        updateRewards(msg.sender);

        LiquidityProvider storage provider = liquidityProviders[msg.sender];
        uint256 shareOfPool = (_lpTokens * 1e18) / lpToken.totalSupply();
        uint256 liquidityToRemove = (shareOfPool * liquidityPool) / 1e18;

        // Calculate impermanent loss protection
        uint256 ilProtection = calculateILProtection(provider, liquidityToRemove);

        uint256 totalToReturn = liquidityToRemove + ilProtection + provider.accumulatedRewards;

        provider.liquidity -= liquidityToRemove;
        provider.accumulatedRewards = 0;
        liquidityPool -= liquidityToRemove;

        lpToken.burn(msg.sender, _lpTokens);

        for (uint256 i = 0; i < outcomeTokens.length; i++) {
            uint256 tokenAmount = (shareOfPool * outcomeTokens[i].balanceOf(address(this))) / 1e18;
            outcomeTokens[i].burn(address(this), tokenAmount);
        }

        require(predictionToken.transfer(msg.sender, totalToReturn), "Transfer failed");

        updateProviderTier(msg.sender);
        uint256 liquidityChange = (liquidityToRemove * 100) / liquidityPool;
        reputationSystem.updateReputation(msg.sender, liquidityChange, 0, 1);

        emit LiquidityRemoved(msg.sender, liquidityToRemove, _lpTokens, ilProtection);
        emit LiquidityChanged(liquidityPool, getOutcomeReserves());
    }

    function calculateILProtection(LiquidityProvider storage provider, uint256 liquidityToRemove) internal view returns (uint256) {
        uint256 currentPrice = getCurrentPrice();
        uint256 priceRatio = (currentPrice * 1e18) / provider.entryPrice;
        
        // Calculate IL percentage (simplified formula)
        uint256 ilPercentage = ((2 * Math.sqrt(priceRatio * 1e18)) / (1e18 + priceRatio)) - 1e18;
        
        // Calculate base IL amount
        uint256 ilAmount = (liquidityToRemove * ilPercentage) / 1e18;
        
        // Apply time-based vesting of IL protection
        uint256 timeElapsed = block.timestamp - provider.lastUpdateTime;
        uint256 vestingPercentage = Math.min(timeElapsed * 1e18 / IL_PROTECTION_PERIOD, 1e18);
        
        // Apply max protection cap
        uint256 maxProtection = (liquidityToRemove * MAX_IL_PROTECTION) / 10000;
        
        return Math.min(ilAmount * vestingPercentage / 1e18, maxProtection);
    }

    function claimRewards() external nonReentrant {
        updateRewards(msg.sender);
        
        LiquidityProvider storage provider = liquidityProviders[msg.sender];
        uint256 rewardsToClaim = provider.accumulatedRewards;
        require(rewardsToClaim > 0, "No rewards to claim");
        
        provider.accumulatedRewards = 0;
        
        require(predictionToken.transfer(msg.sender, rewardsToClaim), "Reward transfer failed");
        
        emit RewardsClaimed(msg.sender, rewardsToClaim);
    }


    function getOutcomeReserves() internal view returns (uint256[] memory) {
        uint256[] memory reserves = new uint256[](outcomeTokens.length);
        for (uint256 i = 0; i < outcomeTokens.length; i++) {
            reserves[i] = outcomeTokens[i].balanceOf(address(this));
        }
        return reserves;
    }    

    function trade(
        uint256 _outcomeIndex,
        uint256 _amount,
        uint256 _maxSlippage,
        bool _isBuy
    ) external onlyActivePhase onlyBeforeEndTime nonReentrant {
        require(_outcomeIndex < outcomeTokens.length, "Invalid outcome");
        require(_amount > 0, "Amount must be greater than 0");
        require(_maxSlippage <= MAX_SLIPPAGE, "Slippage tolerance too high");

        calculateDynamicFee();

        if (_isBuy) {
            recordPrediction(msg.sender, _outcomeIndex, _amount);
        }    

        uint256 inputReserve = _isBuy
            ? liquidityPool
            : outcomeTokens[_outcomeIndex].balanceOf(address(this));
        uint256 outputReserve = _isBuy
            ? outcomeTokens[_outcomeIndex].balanceOf(address(this))
            : liquidityPool;

        uint256 inputAmountWithFee = _amount * (FEE_DENOMINATOR - FEE);
        (uint256 outputAmount, uint256 newPrice) = calculateTradeOutcome(
            inputReserve,
            outputReserve,
            inputAmountWithFee,
            _isBuy
        );

        uint256 slippage = calculateSlippage(
            inputReserve,
            outputReserve,
            _amount,
            outputAmount,
            _isBuy
        );
        require(slippage <= _maxSlippage, "Slippage tolerance exceeded");

        uint256 priceImpact = calculatePriceImpact(
            inputReserve,
            outputReserve,
            _amount,
            outputAmount
        );
        require(priceImpact <= MAX_PRICE_IMPACT, "Price impact too high");

        uint256 averagePriceImpact = getAveragePriceImpact(_outcomeIndex);
        require(
            averagePriceImpact <= MAX_PRICE_IMPACT,
            "Average price impact too high"
        );

        executeTrade(msg.sender, _outcomeIndex, _amount, outputAmount, _isBuy);

        uint256 feeAmount = _amount - (inputAmountWithFee / FEE_DENOMINATOR);
        protocolFees += feeAmount;

        updateTWAP(_outcomeIndex, newPrice);
        updatePriceImpactHistory(_outcomeIndex, priceImpact);

        emit PositionTaken(
            msg.sender,
            _outcomeIndex,
            _amount,
            outputAmount,
            priceImpact,
            slippage,
            mevProtection,
            nonce
        );
        uint256 accuracyChange = _isBuy ? 0 : calculateAccuracyChange(msg.sender, _outcomeIndex, _amount);
        reputationSystem.updateReputation(msg.sender, 0, accuracyChange, 1);
    }

    function distributeRewards() internal {
        require(currentPhase == Phase.Settled, "Market not settled");

        for (uint256 i = 0; i < outcomeTokens.length; i++) {
            OutcomeToken token = outcomeTokens[i];
            address[] memory holders = token.getHolders();
            
            for (uint256 j = 0; j < holders.length; j++) {
                address predictor = holders[j];
                uint256 stake = token.balanceOf(predictor);
                
                if (i == winningOutcomeIndex) {
                    uint256 reward = calculateReward(predictor, stake);
                    predictionToken.mint(predictor, reward);
                    emit RewardDistributed(predictor, reward);

                    // Add governance rewards
                    uint256 governanceReward = (reward * 10) / 100; // 10% of the prediction reward
                    governanceRewards.fundRewardPool(governanceReward);
                }
                
                uint256 accuracyChange = i == winningOutcomeIndex ? 100 : 0;
                reputationSystem.updateReputation(predictor, 0, accuracyChange, 1);
                
                updatePredictorStats(predictor, i == winningOutcomeIndex, stake);
            }
        }
    }

    // Add this function to set the GovernanceRewards contract address
    function setGovernanceRewards(address _governanceRewards) external onlyOwner {
        governanceRewards = GovernanceRewards(_governanceRewards);
    }

    function stakeRewardsExternally(address _protocolAddress, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(predictionToken.balanceOf(msg.sender) >= _amount, "Insufficient balance");

        predictionToken.safeTransferFrom(msg.sender, address(treasury.externalStakingManager()), _amount);
        treasury.externalStakingManager().stake(_protocolAddress, _amount);

        emit RewardsStakedExternally(msg.sender, _protocolAddress, _amount);
    }

    function calculateAccuracyChange(address user, uint256 outcomeIndex, uint256 amount) internal view returns (uint256) {
        PredictorStats storage stats = predictorStats[user];
        if (stats.totalPredictions == 0) return 0;

        uint256 currentAccuracy = (stats.correctPredictions * 10000) / stats.totalPredictions;
        uint256 newTotalPredictions = stats.totalPredictions + 1;
        uint256 newCorrectPredictions = stats.correctPredictions + (outcomeIndex == winningOutcomeIndex ? 1 : 0);
        uint256 newAccuracy = (newCorrectPredictions * 10000) / newTotalPredictions;

        return newAccuracy > currentAccuracy ? newAccuracy - currentAccuracy : 0;
    }

    function getUserReputation(address user) external view returns (uint256 liquidityScore, uint256 accuracyScore, uint256 totalParticipation, uint256 overallReputation) {
        (liquidityScore, accuracyScore, totalParticipation) = reputationSystem.getReputation(user);
        overallReputation = reputationSystem.getOverallReputation(user);
    }

    function calculateReward(address predictor, uint256 stake) internal view returns (uint256) {
        PredictorStats storage stats = predictorStats[predictor];
        uint256 baseReward = (stake * ACCURACY_REWARD_RATE) / 10000;
        
        // Early predictor bonus
        if (stats.lastPredictionTimestamp <= startTime + EARLY_PREDICTOR_THRESHOLD) {
            baseReward += (baseReward * EARLY_PREDICTOR_BONUS) / 10000;
        }
        
        // Streak bonus
        uint256 streakBonus = Math.min(stats.streak * STREAK_BONUS_RATE, MAX_STREAK_BONUS);
        baseReward += (baseReward * streakBonus) / 10000;
        
        return baseReward;
    }

    function updatePredictorStats(address predictor, bool isCorrect, uint256 stake) internal {
        PredictorStats storage stats = predictorStats[predictor];
        if (isCorrect) {
            stats.correctPredictions++;
        }
        stats.totalStaked += stake;
    }

    function recordPrediction(address predictor, uint256 outcomeIndex, uint256 amount) internal {
        PredictorStats storage stats = predictorStats[predictor];
        stats.totalPredictions++;
        stats.totalStaked += amount;

        if (block.timestamp <= startTime + EARLY_PREDICTOR_THRESHOLD) {
            stats.lastPredictionTimestamp = block.timestamp;
        }

        updateStreak(stats);
    }

    function updateStreak(PredictorStats storage stats) internal {
        if (stats.lastPredictionTimestamp + 1 days >= block.timestamp) {
            stats.streak++;
            if (stats.streak > stats.highestStreak) {
                stats.highestStreak = stats.streak;
            }
        } else {
            stats.streak = 1;
        }
        stats.lastPredictionTimestamp = block.timestamp;
    }

    function calculateTradeOutcome(
        uint256 inputReserve,
        uint256 outputReserve,
        uint256 inputAmount,
        bool isBuy
    ) internal view returns (uint256 outputAmount, uint256 newPrice) {
        uint256 k = inputReserve * outputReserve;
        uint256 currentPrice = (inputReserve * 1e18) /
            (inputReserve + outputReserve);

        // Calculate new reserves based on CPMM
        uint256 newInputReserve = isBuy
            ? inputReserve + inputAmount
            : inputReserve - inputAmount;
        uint256 newOutputReserve = k / newInputReserve;

        // Calculate new price based on CPMM
        uint256 newCPMMPrice = (newInputReserve * 1e18) /
            (newInputReserve + newOutputReserve);

        // Apply curve-based adjustment
        newPrice = applyCurveAdjustment(newCPMMPrice);

        // Recalculate output amount based on the curve-adjusted price
        outputAmount = isBuy
            ? (inputAmount * 1e18) / newPrice
            : (inputAmount * newPrice) / 1e18;

        // Ensure the output amount doesn't exceed the available reserve
        outputAmount = Math.min(outputAmount, outputReserve);
    }

    function applyCurveAdjustment(
        uint256 price
    ) internal pure returns (uint256) {
        if (price < MIN_PRICE) {
            return MIN_PRICE;
        } else if (price > MAX_PRICE) {
            return MAX_PRICE;
        }

        uint256 midPrice = 5e17; // 0.5
        if (price == midPrice) {
            return price;
        }

        uint256 adjustment = ((price - midPrice) * CURVE_FACTOR) / midPrice;
        uint256 adjustedPrice = price + adjustment;

        return Math.max(MIN_PRICE, Math.min(adjustedPrice, MAX_PRICE));
    }

    function calculateSlippage(
        uint256 inputReserve,
        uint256 outputReserve,
        uint256 inputAmount,
        uint256 outputAmount,
        bool isBuy
    ) internal pure returns (uint256) {
        uint256 expectedPrice = (inputReserve * 1e18) / outputReserve;
        uint256 actualPrice = (inputAmount * 1e18) / outputAmount;

        return
            isBuy
                ? ((actualPrice - expectedPrice) * 10000) / expectedPrice
                : ((expectedPrice - actualPrice) * 10000) / expectedPrice;
    }

    function executeTrade(
        address trader,
        uint256 outcomeIndex,
        uint256 inputAmount,
        uint256 outputAmount,
        bool isBuy
    ) internal {
        if (isBuy) {
            require(
                predictionToken.transferFrom(
                    trader,
                    address(this),
                    inputAmount
                ),
                "Transfer failed"
            );
            outcomeTokens[outcomeIndex].transfer(trader, outputAmount);
        } else {
            require(
                outcomeTokens[outcomeIndex].transferFrom(
                    trader,
                    address(this),
                    inputAmount
                ),
                "Transfer failed"
            );
            require(
                predictionToken.transfer(trader, outputAmount),
                "Transfer failed"
            );
        }
    }

    uint256 mevProtection = calculateMEVProtection(inputAmount, outputAmount);
    outputAmount = outputAmount * (FEE_DENOMINATOR - mevProtection) / FEE_DENOMINATOR;

    function calculatePriceImpact(
        uint256 inputReserve,
        uint256 outputReserve,
        uint256 inputAmount,
        uint256 outputAmount
    ) internal pure returns (uint256) {
        uint256 idealOutputAmount = (inputAmount * outputReserve) /
            inputReserve;
        if (idealOutputAmount <= outputAmount) {
            return 0;
        }
        return ((idealOutputAmount - outputAmount) * 10000) / idealOutputAmount;
    }

    function updatePriceImpactHistory(uint256 _outcomeIndex, uint256 _priceImpact) internal {
        CircularBuffer storage buffer = priceImpactHistory[_outcomeIndex];
        if (buffer.values.length == 0) {
            buffer.values = new uint256[](10); // Store last 10 price impacts
        }
        if (buffer.count < buffer.values.length) {
            buffer.count++;
        } else {
            buffer.sum -= buffer.values[buffer.index];
        }
        buffer.sum += _priceImpact;
        buffer.values[buffer.index] = _priceImpact;
        buffer.index = (buffer.index + 1) % buffer.values.length;

        emit PriceImpactRecorded(_outcomeIndex, _priceImpact, getAveragePriceImpact(_outcomeIndex));
    }

    function getAveragePriceImpact(
        uint256 _outcomeIndex
    ) public view returns (uint256) {
        CircularBuffer storage buffer = priceImpactHistory[_outcomeIndex];
        if (buffer.count == 0) return 0;
        return buffer.sum / buffer.count;
    }

    function calculateMEVProtection(uint256 inputAmount, uint256 outputAmount) internal view returns (uint256) {
        uint256 expectedPrice = getCurrentPrice(outcomeIndex);
        uint256 actualPrice = (inputAmount * 1e18) / outputAmount;
        uint256 priceDifference = actualPrice > expectedPrice ? actualPrice - expectedPrice : expectedPrice - actualPrice;
        uint256 mevProtection = (priceDifference * MAX_MEV_PROTECTION) / expectedPrice;
        return Math.min(mevProtection, MAX_MEV_PROTECTION);
    }

    function getOutcomeReserves() internal view returns (uint256[] memory) {
    uint256[] memory reserves = new uint256[](outcomeTokens.length);
    for (uint256 i = 0; i < outcomeTokens.length; i++) {
            reserves[i] = outcomeTokens[i].balanceOf(address(this));
        }
        return reserves;
    }
    

    function getCurrentPrice(uint256 outcomeIndex) public view returns (uint256) {
    uint256 outcomeReserve = outcomeTokens[outcomeIndex].balanceOf(address(this));
    uint256 totalReserve = liquidityPool + outcomeReserve;
        return (outcomeReserve * 1e18) / totalReserve;
    }

    function calculateMinimumOutputAmount(
        uint256 _outcomeIndex,
        uint256 _amount,
        uint256 _maxSlippage,
        bool _isBuy
    ) public view returns (uint256) {
        uint256 currentPrice = getCurrentPrice(_outcomeIndex);
        uint256 idealOutputAmount = _isBuy
            ? (_amount * FEE_DENOMINATOR) / currentPrice
            : (_amount * currentPrice) / FEE_DENOMINATOR;
        uint256 slippageAdjustment = (idealOutputAmount * _maxSlippage) / 10000;
        return
            _isBuy
                ? idealOutputAmount - slippageAdjustment
                : idealOutputAmount + slippageAdjustment;
    }

    function lockMarket() external onlyOwner {
        require(currentPhase == Phase.Active, "Market must be active to lock");
        require(
            block.timestamp >= endTime - 1 hours,
            "Can only lock 1 hour before end time"
        );
        currentPhase = Phase.Locked;
        emit PhaseSwitched(Phase.Locked);
    }

    function startResolution() external onlyOwner {
        require(
            currentPhase == Phase.Locked,
            "Market must be locked to start resolution"
        );
        require(
            block.timestamp >= endTime,
            "Cannot start resolution before end time"
        );
        currentPhase = Phase.Resolution;
        emit PhaseSwitched(Phase.Resolution);
    }

    function settleMarket() internal {
        require(
            currentPhase == Phase.Resolution,
            "Market must be in resolution phase to settle"
        );
        require(
            winningOutcomeIndex < outcomeTokens.length,
            "Winning outcome must be set"
        );
        currentPhase = Phase.Settled;
        emit PhaseSwitched(Phase.Settled);
    }

    function requestResolution() external onlyOwner {
        require(currentPhase == Phase.Resolution, "Not in resolution phase");
        require(oracleRequestId == bytes32(0), "Resolution already requested");
        oracleRequestId = oracle.requestMarketOutcome(
            uint256(uint160(address(this)))
        );
        emit MarketResolutionRequested(oracleRequestId);
    }

    function fulfillResolution(bytes32 _requestId, uint256 _outcome) external {
        require(msg.sender == address(oracle), "Only oracle can fulfill");
        require(currentPhase == Phase.Resolution, "Not in resolution phase");
        require(_requestId == oracleRequestId, "Invalid request ID");
        require(_outcome < outcomeTokens.length, "Invalid outcome");
        winningOutcomeIndex = _outcome;
        settleMarket();
        emit MarketResolutionFulfilled(_outcome);
    }

    function claimWinnings() external nonReentrant {
        require(currentPhase == Phase.Settled, "Market not settled");
        uint256 winningTokenBalance = outcomeTokens[winningOutcomeIndex]
            .balanceOf(msg.sender);
        require(winningTokenBalance > 0, "No winning tokens to claim");
        outcomeTokens[winningOutcomeIndex].burn(
            msg.sender,
            winningTokenBalance
        );
        uint256 winnings = (winningTokenBalance * liquidityPool) /
            outcomeTokens[winningOutcomeIndex].totalSupply();
        liquidityPool -= winnings;
        require(
            predictionToken.transfer(msg.sender, winnings),
            "Transfer failed"
        );
        emit WinningsClaimed(msg.sender, winnings);
    }

    function distributeFees() external onlyOwner {
        require(protocolFees > 0, "No fees to distribute");
        uint256 feesToDistribute = protocolFees;
        protocolFees = 0;
        require(
            predictionToken.transfer(address(treasury), feesToDistribute),
            "Fee transfer failed"
        );
        emit FeeDistributed(address(treasury), feesToDistribute);
    }

    function updateOracle(address _newOracleAddress) external onlyOwner {
        require(_newOracleAddress != address(0), "Invalid oracle address");
        oracle = IOracle(_newOracleAddress);
        emit OracleUpdated(_newOracleAddress);
    }

    function requestPriceFetch(uint256 outcomeIndex) external returns (bytes32) {
        bytes32 requestId = keccak256(abi.encodePacked(msg.sender, outcomeIndex, block.timestamp));
        emit PriceFetchRequested(msg.sender, outcomeIndex, requestId);
        return requestId;
    }

    function fulfillPriceFetch(bytes32 requestId, uint256 price) external onlyOracle {
        emit PriceFetchFulfilled(msg.sender, outcomeIndex, price);
        // Implement any necessary logic to use the fetched price
    }

    function calculateDynamicFee() internal {
        uint256 timeSinceLastTrade = block.timestamp - lastTradeTimestamp;
        if (timeSinceLastTrade > VOLATILITY_PERIOD) {
            cumulativeVolatility = 0;
        } else {
            cumulativeVolatility =
                (cumulativeVolatility *
                    (VOLATILITY_PERIOD - timeSinceLastTrade) +
                    cumulativeVolatility *
                    timeSinceLastTrade) /
                VOLATILITY_PERIOD;
        }
        lastTradeTimestamp = block.timestamp;
        uint256 dynamicFee = BASE_FEE +
            (cumulativeVolatility * (MAX_FEE - BASE_FEE)) /
            10000;
        FEE = dynamicFee > MAX_FEE ? MAX_FEE : dynamicFee;

        emit FeeUpdated(FEE);
    }

    function updateTWAP(uint256 _outcomeIndex, uint256 _price) internal {
        TWAPObservation[] storage observations = twapObservations[
            _outcomeIndex
        ];
        if (observations.length == MAX_OBSERVATIONS) {
            for (uint i = 0; i < MAX_OBSERVATIONS - 1; i++) {
                observations[i] = observations[i + 1];
            }
            observations[MAX_OBSERVATIONS - 1] = TWAPObservation(
                block.timestamp,
                _price
            );
        } else {
            observations.push(TWAPObservation(block.timestamp, _price));
        }

        emit TWAPUpdated(_outcomeIndex, getTWAP(_outcomeIndex));
    }

    function getTWAP(uint256 _outcomeIndex) public view returns (uint256) {
        TWAPObservation[] memory observations = twapObservations[_outcomeIndex];
        require(observations.length > 0, "No price observations");
        uint256 timeWeightedSum = 0;
        uint256 timeSum = 0;
        uint256 lastTimestamp = observations[0].timestamp;
        for (uint i = 1; i < observations.length; i++) {
            uint256 timeElapsed = observations[i].timestamp - lastTimestamp;
            timeWeightedSum += observations[i - 1].price * timeElapsed;
            timeSum += timeElapsed;
            lastTimestamp = observations[i].timestamp;
        }
        timeWeightedSum +=
            observations[observations.length - 1].price *
            (block.timestamp - lastTimestamp);
        timeSum += block.timestamp - lastTimestamp;
        return timeWeightedSum / timeSum;
    }
}
