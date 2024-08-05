// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Treasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ReferralProgram public referralProgram;
    ExternalStakingManager public externalStakingManager;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    IERC20 public predictionToken;
    
    uint256 public constant LIQUIDITY_PROVIDER_SHARE = 8000; // 80%
    uint256 public constant PROTOCOL_DEVELOPMENT_SHARE = 2000; // 20%
    uint256 public constant BASIS_POINTS = 10000;

    mapping(address => uint256) public marketFees;
    uint256 public totalProtocolFees;

    event FeeReceived(address indexed from, uint256 amount);
    event FeeDistributed(address indexed to, uint256 amount, string purpose);
    event TokenWhitelisted(IERC20 indexed token);
    event MarketAdded(address indexed marketAddress);
    event MarketRemoved(address indexed marketAddress);

    constructor(address _predictionTokenAddress, address _governanceAddress) {
        predictionToken = IERC20(_predictionTokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, _governanceAddress);
    }

    function receiveFees(uint256 amount) external nonReentrant onlyRole(MARKET_ROLE) {
        require(predictionToken.transferFrom(msg.sender, address(this), amount), "Fee transfer failed");
        
        uint256 liquidityProviderAmount = (amount * LIQUIDITY_PROVIDER_SHARE) / BASIS_POINTS;
        uint256 protocolAmount = amount - liquidityProviderAmount;

        marketFees[msg.sender] += liquidityProviderAmount;
        totalProtocolFees += protocolAmount;

        emit FeeReceived(msg.sender, amount);
    }

    function setExternalStakingManager(address _externalStakingManager) external onlyRole(GOVERNANCE_ROLE) {
        require(_externalStakingManager != address(0), "Invalid address");
        externalStakingManager = ExternalStakingManager(_externalStakingManager);
        emit ExternalStakingManagerSet(_externalStakingManager);
    }

    function distributeLiquidityProviderFees(address marketAddress, address recipient, uint256 amount) external nonReentrant onlyRole(MARKET_ROLE) {
        require(marketFees[marketAddress] >= amount, "Insufficient market fees");
        marketFees[marketAddress] -= amount;
        predictionToken.safeTransfer(recipient, amount);
        emit FeeDistributed(recipient, amount, "Liquidity Provider");
    }

    function setReferralProgram(address _referralProgram) external onlyRole(GOVERNANCE_ROLE) {
        require(_referralProgram != address(0), "Invalid referral program address");
        referralProgram = ReferralProgram(_referralProgram);
        emit ReferralProgramSet(_referralProgram);
    }

    function distributeProtocolFees(address recipient, uint256 amount) external nonReentrant onlyRole(GOVERNANCE_ROLE) {
        require(totalProtocolFees >= amount, "Insufficient protocol fees");
        totalProtocolFees -= amount;
        predictionToken.safeTransfer(recipient, amount);
        emit FeeDistributed(recipient, amount, "Protocol Development");
    }

    function addMarket(address marketAddress) external onlyRole(GOVERNANCE_ROLE) {
        grantRole(MARKET_ROLE, marketAddress);
        emit MarketAdded(marketAddress);
    }

    function removeMarket(address marketAddress) external onlyRole(GOVERNANCE_ROLE) {
        revokeRole(MARKET_ROLE, marketAddress);
        emit MarketRemoved(marketAddress);
    }

    function getMarketFees(address marketAddress) external view returns (uint256) {
        return marketFees[marketAddress];
    }

    function getTotalProtocolFees() external view returns (uint256) {
        return totalProtocolFees;
    }
}