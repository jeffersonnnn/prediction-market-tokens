// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IChainAdapter {
    function getChainId() external view returns (uint256);
    function getNativeTokenBalance(address account) external view returns (uint256);
    function sendNativeToken(address payable recipient, uint256 amount) external payable returns (bool);
    function estimateGas(address to, uint256 value, bytes calldata data) external view returns (uint256);
    function getBlockNumber() external view returns (uint256);
    function getBlockTimestamp() external view returns (uint256);
    function getTransactionReceipt(bytes32 txHash) external view returns (bool success, uint256 gasUsed);
    function isContract(address account) external view returns (bool);
}

abstract contract BaseChainAdapter is IChainAdapter {
    function getChainId() public view virtual override returns (uint256) {
        return block.chainid;
    }

    function getNativeTokenBalance(address account) public view virtual override returns (uint256) {
        return account.balance;
    }

    function sendNativeToken(address payable recipient, uint256 amount) public payable virtual override returns (bool) {
        (bool success, ) = recipient.call{value: amount}("");
        return success;
    }

    function estimateGas(address to, uint256 value, bytes calldata data) public view virtual override returns (uint256) {
        return gasleft();
    }

    function getBlockNumber() public view virtual override returns (uint256) {
        return block.number;
    }

    function getBlockTimestamp() public view virtual override returns (uint256) {
        return block.timestamp;
    }

    function getTransactionReceipt(bytes32 txHash) public view virtual override returns (bool success, uint256 gasUsed) {
        // This needs to be implemented differently for each chain
        revert("Not implemented");
    }

    function isContract(address account) public view virtual override returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}

contract EthereumAdapter is BaseChainAdapter {
    // Ethereum-specific implementations
}

contract PolygonAdapter is BaseChainAdapter {
    // Polygon-specific implementations
}

contract AvalancheAdapter is BaseChainAdapter {
    // Avalanche-specific implementations
}

interface IChainAdapterFactory {
    function createAdapter(uint256 chainId) external returns (IChainAdapter);
}

contract ChainAdapterFactory is IChainAdapterFactory {
    mapping(uint256 => address) private adapterImplementations;

    event AdapterImplementationSet(uint256 indexed chainId, address implementation);

    function setAdapterImplementation(uint256 chainId, address implementation) external onlyOwner {
        require(implementation != address(0), "Invalid implementation address");
        adapterImplementations[chainId] = implementation;
        emit AdapterImplementationSet(chainId, implementation);
    }

    function createAdapter(uint256 chainId) external override returns (IChainAdapter) {
        address implementation = adapterImplementations[chainId];
        require(implementation != address(0), "No implementation for chain ID");
        return IChainAdapter(createClone(implementation));
    }

    function createClone(address target) internal returns (address result) {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            result := create(0, clone, 0x37)
        }
    }
}