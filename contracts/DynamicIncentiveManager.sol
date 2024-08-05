// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./Market.sol";
import "./PredictionToken.sol";

contract DynamicIncentiveManager is Ownable {
    using SafeMath for uint256;

    Market public market;
    PredictionToken public predictionToken;

    // Constants
    uint256 public constant BASE_LIQUIDITY_INCENTIVE_RATE = 100; // 1%
    uint256 public constant BASE_ACCURACY_INCENTIVE_RATE = 50; // 0.5%
    uint256 public constant MAX_LIQUIDITY_INCENTIVE_RATE = 500; // 5%
    uint256 public constant MAX_ACCURACY_INCENTIVE_RATE = 250; // 2.5%
    uint256 public constant ADJUSTMENT_INTERVAL = 1 hours;
    uint256 public constant BASIS_POINTS = 10000;

    // Dynamic rates
    uint256 public liquidityIncentiveRate;
    uint256 public accuracyIncentiveRate;

    // Market metrics
    uint256 public targetLiquidity;
    uint256 public targetVolume;
    uint256 public targetVolatility;

    // Adjustment weights
    uint256 public liquidityWeight = 4000; // 40%
    uint256 public volumeWeight = 3000; // 30%
    uint256 public volatilityWeight = 2000; // 20%
    uint256 public phaseWeight = 1000; // 10%

    // Historical data
    struct MetricObservation {
        uint256 timestamp;
        uint256 value;
    }

    MetricObservation[] public liquidityHistory;
    MetricObservation[] public volumeHistory;
    MetricObservation[] public volatilityHistory;

    uint256 public lastAdjustmentTime;

    event IncentiveRatesAdjusted(uint256 newLiquidityRate, uint256 newAccuracyRate);
    event TargetMetricsUpdated(uint256 newTargetLiquidity, uint256 newTargetVolume, uint256 newTargetVolatility);
    event AdjustmentWeightsUpdated(uint256 newLiquidityWeight, uint256 newVolumeWeight, uint256 newVolatilityWeight, uint256 newPhaseWeight);

    constructor(address _marketAddress, address _predictionTokenAddress) {
        market = Market(_marketAddress);
        predictionToken = PredictionToken(_predictionTokenAddress);
        liquidityIncentiveRate = BASE_LIQUIDITY_INCENTIVE_RATE;
        accuracyIncentiveRate = BASE_ACCURACY_INCENTIVE_RATE;
        lastAdjustmentTime = block.timestamp;
    }

    function adjustIncentiveRates() external {
        require(block.timestamp >= lastAdjustmentTime.add(ADJUSTMENT_INTERVAL), "Adjustment interval not reached");

        uint256 currentLiquidity = market.liquidityPool();
        uint256 currentVolume = calculateRecentVolume();
        uint256 currentVolatility = calculateRecentVolatility();
        Market.Phase currentPhase = market.currentPhase();

        uint256 liquidityFactor = calculateMetricFactor(currentLiquidity, targetLiquidity);
        uint256 volumeFactor = calculateMetricFactor(currentVolume, targetVolume);
        uint256 volatilityFactor = calculateMetricFactor(currentVolatility, targetVolatility);
        uint256 phaseFactor = calculatePhaseFactor(currentPhase);

        uint256 totalAdjustment = liquidityFactor.mul(liquidityWeight)
            .add(volumeFactor.mul(volumeWeight))
            .add(volatilityFactor.mul(volatilityWeight))
            .add(phaseFactor.mul(phaseWeight))
            .div(BASIS_POINTS);

        liquidityIncentiveRate = calculateNewRate(BASE_LIQUIDITY_INCENTIVE_RATE, MAX_LIQUIDITY_INCENTIVE_RATE, totalAdjustment);
        accuracyIncentiveRate = calculateNewRate(BASE_ACCURACY_INCENTIVE_RATE, MAX_ACCURACY_INCENTIVE_RATE, totalAdjustment);

        updateMetricHistory(liquidityHistory, currentLiquidity);
        updateMetricHistory(volumeHistory, currentVolume);
        updateMetricHistory(volatilityHistory, currentVolatility);

        lastAdjustmentTime = block.timestamp;

        emit IncentiveRatesAdjusted(liquidityIncentiveRate, accuracyIncentiveRate);
    }

    function calculateMetricFactor(uint256 current, uint256 target) internal pure returns (uint256) {
        if (current >= target) {
            return BASIS_POINTS;
        }
        return current.mul(BASIS_POINTS).div(target);
    }

    function calculatePhaseFactor(Market.Phase phase) internal pure returns (uint256) {
        if (phase == Market.Phase.Active) {
            return BASIS_POINTS;
        } else if (phase == Market.Phase.Locked) {
            return BASIS_POINTS.mul(8).div(10); // 80%
        } else {
            return BASIS_POINTS.div(2); // 50%
        }
    }

    function calculateNewRate(uint256 baseRate, uint256 maxRate, uint256 adjustmentFactor) internal pure returns (uint256) {
        uint256 adjustmentRange = maxRate.sub(baseRate);
        uint256 adjustment = adjustmentRange.mul(BASIS_POINTS.sub(adjustmentFactor)).div(BASIS_POINTS);
        return baseRate.add(adjustment);
    }

    function calculateRecentVolume() internal view returns (uint256) {
        require(volumeHistory.length > 0, "No volume history");
        uint256 recentVolume = 0;
        uint256 startTime = block.timestamp.sub(1 days);
        for (uint256 i = volumeHistory.length - 1; i >= 0 && volumeHistory[i].timestamp >= startTime; i--) {
            recentVolume = recentVolume.add(volumeHistory[i].value);
        }
        return recentVolume;
    }

    function calculateRecentVolatility() internal view returns (uint256) {
        require(volatilityHistory.length > 0, "No volatility history");
        uint256 recentVolatility = 0;
        uint256 startTime = block.timestamp.sub(1 days);
        uint256 count = 0;
        for (uint256 i = volatilityHistory.length - 1; i >= 0 && volatilityHistory[i].timestamp >= startTime; i--) {
            recentVolatility = recentVolatility.add(volatilityHistory[i].value);
            count++;
        }
        return count > 0 ? recentVolatility.div(count) : 0;
    }

    function updateMetricHistory(MetricObservation[] storage history, uint256 newValue) internal {
        if (history.length >= 24) {
            for (uint256 i = 0; i < 23; i++) {
                history[i] = history[i + 1];
            }
            history[23] = MetricObservation(block.timestamp, newValue);
        } else {
            history.push(MetricObservation(block.timestamp, newValue));
        }
    }

    function setTargetMetrics(uint256 _targetLiquidity, uint256 _targetVolume, uint256 _targetVolatility) external onlyOwner {
        targetLiquidity = _targetLiquidity;
        targetVolume = _targetVolume;
        targetVolatility = _targetVolatility;
        emit TargetMetricsUpdated(targetLiquidity, targetVolume, targetVolatility);
    }

    function setAdjustmentWeights(uint256 _liquidityWeight, uint256 _volumeWeight, uint256 _volatilityWeight, uint256 _phaseWeight) external onlyOwner {
        require(_liquidityWeight.add(_volumeWeight).add(_volatilityWeight).add(_phaseWeight) == BASIS_POINTS, "Weights must sum to 10000");
        liquidityWeight = _liquidityWeight;
        volumeWeight = _volumeWeight;
        volatilityWeight = _volatilityWeight;
        phaseWeight = _phaseWeight;
        emit AdjustmentWeightsUpdated(liquidityWeight, volumeWeight, volatilityWeight, phaseWeight);
    }

    function getLiquidityIncentiveRate() external view returns (uint256) {
        return liquidityIncentiveRate;
    }

    function getAccuracyIncentiveRate() external view returns (uint256) {
        return accuracyIncentiveRate;
    }
}