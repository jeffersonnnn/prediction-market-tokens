# Prediction Market Tokens

A decentralized prediction market platform using meme coins as fungible tokens for continuous, unlimited upside potential.

## Project Overview

This project aims to revolutionize prediction markets by leveraging blockchain technology and tokenomics. Instead of traditional binary outcomes, our platform uses meme coins (e.g., $BIDEN, $TRUMP) as fungible tokens, allowing for more nuanced expressions of beliefs and continuous trading throughout an event's lifecycle.

## Key Features

- Continuous trading with unlimited upside potential
- Cross-chain functionality
- Dynamic incentive system
- Governance mechanism
- Referral program
- External staking options

## Smart Contracts

The project consists of several key smart contracts:

1. Market.sol: The core contract for creating and managing prediction markets
2. MarketFactory.sol: Responsible for deploying new markets
3. PredictionToken.sol: The ERC20 token used for predictions and liquidity provision
4. Governance.sol: Handles on-chain governance decisions
5. Treasury.sol: Manages protocol fees and funds
6. ReferralProgram.sol: Implements a referral system for user acquisition
7. DynamicIncentiveManager.sol: Adjusts incentives based on market conditions
8. ExternalStakingManager.sol: Allows staking of prediction tokens in external protocols

## Development Progress

We are currently in Phase 1 of our development roadmap:

```
startLine: 1
endLine: 19
```

## Getting Started

1. Clone the repository
2. Install dependencies:
   ```
   npm install
   ```
3. Set up your environment variables in a `.env` file
4. Compile the contracts:
   ```
   npx hardhat compile
   ```
5. Run tests:
   ```
   npx hardhat test
   ```

## Contributing

We welcome contributions to the project. Please see our CONTRIBUTING.md file for guidelines.

## License

This project is licensed under the MIT License.

## Contact

For any queries or suggestions, please open an issue in the GitHub repository.