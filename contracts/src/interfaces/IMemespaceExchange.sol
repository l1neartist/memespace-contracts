// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IMemespaceExchange {
    // mutative
    function addLiquidity(uint256 minLpTokens, uint256 deadline) external payable returns (uint256);
    function removeLiquidity(
        uint256 lpTokensToBurn,
        uint256 minEthWithdrawn,
        uint256 minTokensWithdrawn,
        uint256 deadline
    ) external returns (uint256 ethAmount, uint256 tokenAmount);
    function swapEthForToken(uint256 minTokens, uint256 deadline) external payable returns (uint256 tokensBought);
    function swapTokenForEth(uint256 tokensToSell, uint256 minEth, uint256 deadline) external returns (uint256 ethOutput);
    function removeOwnerLiquidity(uint256 lpTokensToUnlock, uint256 minEthWithdrawn, uint256 minTokensWithdrawn)
        external
        returns (uint256 ethAmount, uint256 tokenAmount);
    function startUnlockPeriodForOwnerLiquidity(uint256 lpTokensToUnlock) external;
    function lockMoreOwnerLiquidity(uint256 minLpTokens, uint256 deadline) external payable returns (uint256 liquidityMinted);
    function getExchangeMetadata() external view returns (string memory, string memory, address, uint256, uint256, string memory,uint256);
    function getLiquidityData() external view returns (uint256, uint256, uint256, uint256);
    function getOwnerLiquidityData() external view returns (uint256, bool, uint256, uint256);
    function getExpectedReturnForEth(uint256 ethAmount) external view returns (uint256);
    function getUserBalances(address user) external view returns (uint256, uint256);
    function getTokenAmountForEthLiquidity(uint256 ethToDeposit) external view returns (uint256);
    function getReserveEth() external view returns (uint256);
}
