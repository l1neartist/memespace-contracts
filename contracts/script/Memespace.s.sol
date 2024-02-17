// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import "../src/MemespaceFactory.sol";
import "../src/MemespaceExchange.sol";
import "../src/MemesToken.sol";

contract MemespaceScript is Script {
    function setUp() public {}

    function run() public {
        MemesToken token = new MemesToken();
        address feeBeneficiary = 0x231Ae5AdCcC2dbfF1B457CAf2A3A74Ac7DDC960E;
        MemespaceFactory factory = new MemespaceFactory(feeBeneficiary, address(token));
        token.setFactoryAddress(address(factory));

        string memory symbol = "ABCD";
        uint256 initialLiquidity = 1e16;
        uint256 registrationFee = factory.getRegistrationFee(symbol);
        MemespaceFactory.CreateExchangeParams memory params =
            MemespaceFactory.CreateExchangeParams(symbol, "ABCD Token", 1e16, 1000e18, 1000, "", address(0));
        address exchange1 = factory.createExchange{value: initialLiquidity + registrationFee}(params);
        
        MemespaceExchange memespaceExchange = MemespaceExchange(payable(exchange1));
        memespaceExchange.swapEthForToken{value: 1e16}(1, block.timestamp + 100);
        // memespaceExchange.claimAllGas();
    }
}
