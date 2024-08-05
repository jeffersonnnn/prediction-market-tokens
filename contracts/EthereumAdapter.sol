pragma solidity ^0.8.24;

import "../interfaces/IChainAdapter.sol";

contract EthereumAdapter is IChainAdapter {
    function getChainId() external view override returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }

    function getBlockTimestamp() external view override returns (uint256) {
        return block.timestamp;
    }

    function getGasPrice() external view override returns (uint256) {
        return tx.gasprice;
    }

    function estimateGas(address to, bytes memory data) external view override returns (uint256) {
        (bool success, bytes memory result) = to.staticcall{gas: gasleft()}(data);
        require(success, "Gas estimation failed");
        return gasleft();
    }

    function sendTransaction(address to, bytes memory data, uint256 value) external override returns (bytes32) {
        (bool success, ) = to.call{value: value}(data);
        require(success, "Transaction failed");
        return bytes32(0); // Ethereum doesn't return transaction hashes directly
    }

    function call(address to, bytes memory data) external view override returns (bool success, bytes memory result) {
        return to.staticcall(data);
    }

    function getBalance(address account) external view override returns (uint256) {
        return account.balance;
    }

    function getNonce(address account) external view override returns (uint256) {
        return account.nonce;
    }

    function getCode(address account) external view override returns (bytes memory) {
        return account.code;
    }

    function getBlockNumber() external view override returns (uint256) {
        return block.number;
    }

    function getBlockHash(uint256 blockNumber) external view override returns (bytes32) {
        return blockhash(blockNumber);
    }
}