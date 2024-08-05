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
    function getGasPrice() external view returns (uint256);
    function getMaxPriorityFeePerGas() external view returns (uint256);
    function getBaseFee() external view returns (uint256);
    function getChainCurrency() external view returns (string memory symbol, uint8 decimals);
    function getBlockGasLimit() external view returns (uint256);
    function getAverageBlockTime() external view returns (uint256);
    function executeCall(address target, uint256 value, bytes calldata data) external returns (bool success, bytes memory result);
    function getChainType() external pure returns (string memory);
}