// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./MarketFactory.sol";
import "./Treasury.sol";
import "./GovernanceRewards.sol";

contract Governance is Ownable {
    enum ProposalType { Generic, FeeAdjustment, NewMarketType, TreasuryAllocation, UpdateMarketParameters }

    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 startTime;
        uint256 endTime;
        bool executed;
        bool vetoed;
        bytes data;
        uint256 sponsorCount;
        ProposalType proposalType;
        mapping(address => bool) hasVoted;
        mapping(address => bool) hasSponsored;
    }

    ERC20Votes public governanceToken;
    uint256 public proposalCount;
    uint256 public votingPeriod = 3 days;
    uint256 public votingDelay = 1 days;
    uint256 public proposalThreshold = 100000 * 10**18; // 100,000 tokens
    uint256 public constant MAX_ACTIVE_PROPOSALS = 10;
    uint256 public constant SPONSOR_THRESHOLD = 5;
    uint256 public constant VOTE_INCENTIVE = 10 * 10**18; // 10 tokens as reward

    address public vetoAddress;
    uint256 public lastVoteTimestamp;

    Treasury public treasury;
    MarketFactory public marketFactory;
    GovernanceRewards public governanceRewards;

    mapping(uint256 => Proposal) public proposals;
    mapping(string => bool) public marketTypes;

    event ProposalCreated(uint256 indexed proposalId, address proposer, string description, ProposalType proposalType);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event TreasuryAddressUpdated(address indexed newTreasuryAddress);
    event MarketFactoryAddressUpdated(address indexed newMarketFactoryAddress);
    event NewMarketTypeAdded(string marketType);
    event MarketParametersUpdated(uint256 newFee, address newFeeRecipient);

    constructor(address _governanceToken, address _treasury, address _marketFactory) Ownable(msg.sender) {
        governanceToken = ERC20Votes(_governanceToken);
        treasury = Treasury(_treasury);
        marketFactory = MarketFactory(_marketFactory);
    }

    // Update the createProposal function
    function createProposal(string memory _description, address _target, bytes memory _data) external {
        require(token.balanceOf(msg.sender) >= proposalThreshold, "Insufficient tokens to create proposal");
        
        proposals.push(Proposal({
            id: proposalCount,
            description: _description,
            target: _target,
            data: _data,
            forVotes: 0,
            againstVotes: 0,
            status: ProposalStatus.Active,
            createdAt: block.timestamp,
            executor: address(0)
        }));
        
        proposalCount++;
        
        // Record governance participation for proposal creation
        governanceRewards.recordGovernanceParticipation(msg.sender, true, token.balanceOf(msg.sender));
        
        emit ProposalCreated(proposalCount - 1, msg.sender, _target, _description);
    }

    function castVote(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.startTime, "Voting has not started");
        require(block.timestamp <= proposal.endTime, "Voting has ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");

        uint256 votes = governanceToken.getPastVotes(msg.sender, proposal.startTime);
        require(votes > 0, "No voting power");

        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }

        proposal.hasVoted[msg.sender] = true;

        // Record governance participation for voting
        governanceRewards.recordGovernanceParticipation(msg.sender, false, votes);

        // Distribute vote incentive
        require(governanceToken.transfer(msg.sender, VOTE_INCENTIVE), "Vote incentive transfer failed");

        emit Voted(proposalId, msg.sender, support, votes);
    }

    function executeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp > proposal.endTime, "Voting period not ended");
        require(!proposal.executed, "Proposal already executed");
        require(!proposal.vetoed, "Proposal has been vetoed");
        require(proposal.forVotes > proposal.againstVotes, "Proposal did not pass");

        proposal.executed = true;

        if (proposal.proposalType == ProposalType.FeeAdjustment) {
            (uint256 newFee) = abi.decode(proposal.data, (uint256));
            marketFactory.setMarketCreationFee(newFee);
        } else if (proposal.proposalType == ProposalType.NewMarketType) {
            (string memory newMarketType) = abi.decode(proposal.data, (string));
            require(!marketTypes[newMarketType], "Market type already exists");
            marketTypes[newMarketType] = true;
            emit NewMarketTypeAdded(newMarketType);
        } else if (proposal.proposalType == ProposalType.TreasuryAllocation) {
            (address recipient, uint256 amount) = abi.decode(proposal.data, (address, uint256));
            treasury.distributeProtocolFees(recipient, amount);
        } else if (proposal.proposalType == ProposalType.UpdateMarketParameters) {
            (uint256 newFee, address newFeeRecipient) = abi.decode(proposal.data, (uint256, address));
            marketFactory.updateMarketParameters(newFee, newFeeRecipient);
            emit MarketParametersUpdated(newFee, newFeeRecipient);
        }

        emit ProposalExecuted(proposalId);
    }


    // Existing functions: vote, vetoProposal, setVotingPeriod, setTreasuryAddress, setMarketFactoryAddress, setVotingDelay, setProposalThreshold, setVetoAddress

    function setGovernanceRewards(address _governanceRewards) external onlyOwner {
        governanceRewards = GovernanceRewards(_governanceRewards);
    }

    function updateTreasuryAllocation(address recipient, uint256 amount) external onlyOwner {
        treasury.distributeProtocolFees(recipient, amount);
    }

    function updateMarketCreationFee(uint256 newFee) external onlyOwner {
        marketFactory.setMarketCreationFee(newFee);
    }

    function updateMarketParameters(uint256 newFee, address newFeeRecipient) external onlyOwner {
        marketFactory.updateMarketParameters(newFee, newFeeRecipient);
        emit MarketParametersUpdated(newFee, newFeeRecipient);
    }
}