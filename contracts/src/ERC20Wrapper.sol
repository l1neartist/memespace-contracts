// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IMemespaceExchange.sol";

contract ERC20Wrapper is ERC20 {
    IMemespaceExchange exchange;

    constructor(string memory _symbol, address _exchange)
        ERC20(string(abi.encodePacked("Memespace ", _symbol)), string(abi.encodePacked("ms", _symbol)))
    {
        exchange = IMemespaceExchange(_exchange);
    }

    function mint(uint256 minTokens, uint256 deadline) public payable returns (uint256 tokensBought) {
        tokensBought = exchange.swapEthForToken{value: msg.value}(minTokens, deadline);
        _mint(msg.sender, tokensBought);
    }

    function burn(uint256 tokensToSell, uint256 minEth, uint256 deadline) public returns (uint256 ethOutput) {
        _burn(msg.sender, tokensToSell);
        ethOutput = exchange.swapTokenForEth(tokensToSell, minEth, deadline);
        (bool sent,) = msg.sender.call{value: ethOutput}("");
        require(sent);
    }
}
