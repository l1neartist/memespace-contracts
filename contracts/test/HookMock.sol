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


contract HookMock {
    address owner;
    address exchange;

    mapping(address => uint256) public points;

    constructor() {
        owner = msg.sender;
    } 

    function setExchange(address _exchange) public {
        require(msg.sender == owner);
        exchange = _exchange;
    }


    function interact(address user, IHook.Interaction interaction, uint256 lpAmount, uint256 ethAmount, uint256 tokenAmount) external {
        require(msg.sender == exchange);
        if(interaction == IHook.Interaction.SWAP_IN){
            points[user] += ethAmount;
        }
    }
}