// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MemesToken is ERC20 {
    address memespaceFactory;
    address owner;

    constructor() ERC20("Memes Token", "MEMES"){
        owner = msg.sender;
    }

    function mint(address receiver, uint256 amount) external {
        require(msg.sender == memespaceFactory);
        _mint(receiver, amount);
    }

    function setFactoryAddress(address _memespaceFactory) public {
        require(msg.sender == owner);
        memespaceFactory = _memespaceFactory;
    }  

    function transferOwnership(address newOwner) public {
        require(msg.sender == owner);
        owner = newOwner;
    }
}