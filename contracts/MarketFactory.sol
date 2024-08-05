// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PredictionToken.sol";
import "./Market.sol";
import "./Treasury.sol";
import "./Governance.sol";
import "./IMarketFactory.sol";

import "./interfaces/IChainAdapter.sol";
import "./interfaces/IChainAdapterFactory.sol";

contract MarketFactory is IMarketFactory, Ownable, Pausable {
    address[] public markets;
    uint256 public marketCreationFee;
    address public feeRecipient;
    uint256 public marketCreationFee;
    address public feeRecipient;
    PredictionToken public predictionToken;
    Treasury public treasury;
    Governance public governance;
    ReferralProgram public referralProgram;

    event MarketCreated(address indexed marketAddress, string name, uint256 endTime, string[] outcomeNames, uint256 initialLiquidity);
    event MarketCreationFeesUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newRecipient);
    event GovernanceUpdated(address newGovernanceAddress);
    event ChainAdapterFactorySet(address newChainAdapterFactory);


    IChainAdapterFactory public chainAdapterFactory;
    mapping(uint256 => IChainAdapter) public chainAdapters;

    constructor(
        address _predictionTokenAddress,
        uint256 _initialMarketCreationFee,
        address _initialFeeRecipient,
        address _treasuryAddress,
        address _governanceAddress
        address _chainAdapterFactoryAddress
    ) Ownable(msg.sender) {
        predictionToken = PredictionToken(_predictionTokenAddress);
        marketCreationFee = _initialMarketCreationFee;
        feeRecipient = _initialFeeRecipient;
        treasury = Treasury(_treasuryAddress);
        governance = Governance(_governanceAddress);
        referralProgram = new ReferralProgram(address(predictionToken), address(this));
        predictionToken.approve(address(referralProgram), type(uint256).max);
        chainAdapterFactory = IChainAdapterFactory(_chainAdapterFactoryAddress);
    }

    function createMarket(string memory _name, uint256 _endTime, string[] memory _outcomeNames, address _oracleAddress, uint256 _initialLiquidity, uint256 _chainId) public whenNotPaused {
        require(_endTime > block.timestamp, "End time must be in the future");
        require(_outcomeNames.length >= 2, "At least two outcomes are required");
        require(_initialLiquidity > 0, "Initial liquidity must be greater than 0");

        // Collect market creation fee
        require(predictionToken.transferFrom(msg.sender, address(treasury), marketCreationFee), "Market creation fee transfer failed");

        Market newMarket = new Market(_name, _endTime, address(predictionToken), _outcomeNames, _oracleAddress, address(treasury));
        markets.push(address(newMarket));
        treasury.addMarket(address(newMarket));

        IChainAdapter adapter = getOrCreateChainAdapter(_chainId);
        require(adapter.getBlockTimestamp() < _endTime, "End time must be in the future");

        // Transfer initial liquidity to the new market
        require(predictionToken.transferFrom(msg.sender, address(newMarket), _initialLiquidity), "Initial liquidity transfer failed");

        // Add initial liquidity to the market
        newMarket.addLiquidity(_initialLiquidity);

        emit MarketCreated(address(newMarket), _name, _endTime, _outcomeNames, _initialLiquidity);

        // Distribute referral reward
        uint256 referralReward = _initialLiquidity.mul(500).div(10000); // 5% referral reward
        referralProgram.distributeReferralReward(msg.sender, referralReward);
        }

    function setMarketCreationFee(uint256 _newFee) external override {
        require(msg.sender == address(governance), "Only governance can update market creation fee");
        marketCreationFee = _newFee;
        emit MarketCreationFeesUpdated(_newFee);
    }

    function setChainAdapterFactory(address _newChainAdapterFactory) external onlyOwner {
        require(_newChainAdapterFactory != address(0), "Invalid chain adapter factory address");
        chainAdapterFactory = IChainAdapterFactory(_newChainAdapterFactory);
        emit ChainAdapterFactorySet(_newChainAdapterFactory);
    }

    function getOrCreateChainAdapter(uint256 chainId) internal returns (IChainAdapter) {
        if (address(chainAdapters[chainId]) == address(0)) {
            chainAdapters[chainId] = chainAdapterFactory.createAdapter(chainId);
        }
        return chainAdapters[chainId];
    }

    function setReferralProgram(address _referralProgram) external onlyOwner {
        require(_referralProgram != address(0), "Invalid referral program address");
        referralProgram = ReferralProgram(_referralProgram);
        emit ReferralProgramSet(_referralProgram);
    }

    function setFeeRecipient(address _newRecipient) external override {
        require(msg.sender == address(governance), "Only governance can update fee recipient");
        feeRecipient = _newRecipient;
        emit FeeRecipientUpdated(_newRecipient);
    }

    function setGovernance(address _newGovernanceAddress) external onlyOwner {
        require(_newGovernanceAddress != address(0), "Invalid governance address");
        governance = Governance(_newGovernanceAddress);
        emit GovernanceUpdated(_newGovernanceAddress);
    }

    function pauseMarketCreation() external {
        require(msg.sender == address(governance), "Only governance can pause market creation");
        _pause();
    }

    function unpauseMarketCreation() external {
        require(msg.sender == address(governance), "Only governance can unpause market creation");
        _unpause();
    }

    function getMarkets() public view returns (address[] memory) {
        return markets;
    }

    function getMarketCount() public view returns (uint256) {
        return markets.length;
    }
}