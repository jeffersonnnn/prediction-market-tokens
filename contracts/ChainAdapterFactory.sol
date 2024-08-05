pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IChainAdapter.sol";

contract ChainAdapterFactory is Ownable {
    mapping(uint256 => address) public chainAdapters;
    
    event ChainAdapterCreated(uint256 chainId, address adapter);
    event ChainAdapterUpdated(uint256 chainId, address adapter);

    constructor() Ownable(msg.sender) {}

    function createChainAdapter(uint256 chainId, address adapterAddress) external onlyOwner {
        require(chainAdapters[chainId] == address(0), "Adapter already exists for this chain");
        require(adapterAddress != address(0), "Invalid adapter address");
        
        chainAdapters[chainId] = adapterAddress;
        emit ChainAdapterCreated(chainId, adapterAddress);
    }

    function updateChainAdapter(uint256 chainId, address newAdapterAddress) external onlyOwner {
        require(chainAdapters[chainId] != address(0), "Adapter does not exist for this chain");
        require(newAdapterAddress != address(0), "Invalid adapter address");
        
        chainAdapters[chainId] = newAdapterAddress;
        emit ChainAdapterUpdated(chainId, newAdapterAddress);
    }

    function getChainAdapter(uint256 chainId) external view returns (IChainAdapter) {
        address adapterAddress = chainAdapters[chainId];
        require(adapterAddress != address(0), "No adapter found for this chain");
        return IChainAdapter(adapterAddress);
    }
}