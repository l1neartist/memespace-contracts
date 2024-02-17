// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IMemespaceFactory {
    function getFeeBeneficiary() external view returns(address);
    function generateToken(address recipient, uint256 amount) external;
}