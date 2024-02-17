// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IHook {
    enum Interaction {
        SWAP_IN,
        SWAP_OUT,
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY
    }

    function interact(address user, Interaction interaction, uint256 lpAmount, uint256 ethAmount, uint256 tokenAmount)
        external;
}
