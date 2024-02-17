// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {MemespaceFactory} from "../src/MemespaceFactory.sol";
import {IMemespaceExchange} from "../src/interfaces/IMemespaceExchange.sol";
import {MemesToken} from "../src/MemesToken.sol";
import {HookMock} from "./HookMock.sol";



// NB: MUST COMMENT OUT BLAST YIELD FUNCTIONS IN MEMEBLASTEXCHANGE CONSTRUCTOR TO RUN TESTS
contract MemespaceTest is Test {
    MemespaceFactory public factory;
    IMemespaceExchange public memeExchange1;
    MemesToken public token;

    address signer1;
    address signer2; // feeBeneficiary
    address signer3;

    string tokenSymbol1 = "ABC";
    string tokenSymbol2 = "AAA";
    string tokenName1 = "ABC Token";
    uint256 memeTokenSupply = 1000000e18;
    uint256 initialEthLiquidity = 1 ether;
    uint256 swapFee = 1250; //1.25%

    uint256 constant ONE_WEEK = 60 * 60 * 24 * 7;
    uint256 constant INITIAL_LP_SUPPLY_MULTIPLIER = 1000; // see constructor() in MemespaceExchange

    
    function setUp() public {
        (signer1,) = genKeyPair(123);
        (signer2,) = genKeyPair(1234);
        (signer3,) = genKeyPair(12345);

        vm.deal(signer1, 10 ether);
        vm.deal(signer3, 10 ether);
        vm.startPrank(signer1);
        token = new MemesToken();
        factory = new MemespaceFactory(signer2, address(token));
        token.setFactoryAddress(address(factory));

        MemespaceFactory.CreateExchangeParams memory params = MemespaceFactory.CreateExchangeParams(
            tokenSymbol1, tokenName1, initialEthLiquidity, memeTokenSupply, swapFee, "", address(0)
        );
        uint256 registrationFee = factory.getRegistrationFee(tokenSymbol1);

        memeExchange1 = IMemespaceExchange(factory.createExchange{value: initialEthLiquidity + registrationFee}(params));
        vm.stopPrank();
    }

    function testRegistration() public {
        uint256 expectedFee3 = 0.1 ether;
        uint256 expected3 = factory.getRegistrationFee(tokenSymbol2);
        assertEq(expectedFee3, expected3);
        uint256 expectedFee2 = 1 ether;
        uint256 expected2 = factory.getRegistrationFee("AA");
        assertEq(expectedFee2, expected2);
        uint256 expectedFee1 = 10 ether;
        uint256 expected1 = factory.getRegistrationFee("A");
        assertEq(expectedFee1, expected1);

        uint256 fbEthBalBefore = factory.getFeeBeneficiary().balance;
        vm.startPrank(signer3);
        MemespaceFactory.CreateExchangeParams memory params = MemespaceFactory.CreateExchangeParams(
            tokenSymbol2, tokenName1, initialEthLiquidity, memeTokenSupply, swapFee, "", address(0)
        );
        factory.createExchange{value: initialEthLiquidity + expected3}(params);
        vm.stopPrank();

        uint256 fbEthBalAfter = factory.getFeeBeneficiary().balance;
        assertEq(fbEthBalAfter, fbEthBalBefore + expected3);
    }

    function testBaseParams() public {
        (
            string memory tokenSymbol,
            string memory tokenName,
            address poolOwner,
            uint256 memeTokenTotalSupply,
            ,
            ,
            uint256 swapFee_
        ) = memeExchange1.getExchangeMetadata();
        assertEq(tokenSymbol1, tokenSymbol);
        assertEq(tokenName1, tokenName);
        assertEq(signer1, poolOwner);
        assertEq(memeTokenSupply, memeTokenTotalSupply);
        assertEq(swapFee_, swapFee);
    }

    function testBaseLiquidity() public {
        (uint256 poolOwnerStake, uint256 memeTokenSupplyInLiquidity, uint256 lpTokenSupply, uint256 reserveEth) =
            memeExchange1.getLiquidityData();
        // initial LP token balance mint == initial eth provided * 10
        assertEq(initialEthLiquidity * INITIAL_LP_SUPPLY_MULTIPLIER, poolOwnerStake);
        // 90% to liquidity, 10% to creator
        assertEq(memeTokenSupply - (memeTokenSupply / 10), memeTokenSupplyInLiquidity);
        assertEq(initialEthLiquidity * INITIAL_LP_SUPPLY_MULTIPLIER, lpTokenSupply);
        assertEq(initialEthLiquidity, reserveEth);
        (, bool unlockInProgress, uint256 unlockPeriodStart, uint256 lpTokensToUnlock) =
            memeExchange1.getOwnerLiquidityData();
        assertEq(unlockInProgress, false);
        assertEq(unlockPeriodStart, 0);
        assertEq(lpTokensToUnlock, 0);
    }

    function testSwapEthForToken_memeTokenBalances() public {
        uint256 ethAmount = 0.1 ether;
        (, uint256 memeTokenSupplyInLiquidityBefore,,) = memeExchange1.getLiquidityData();
        (uint256 tokenBalanceBefore,) = memeExchange1.getUserBalances(signer3);

        vm.deal(signer3, 1 ether);

        uint256 expectedReturn = memeExchange1.getExpectedReturnForEth(ethAmount);
        vm.startPrank(signer3);
        uint256 tokensBought = memeExchange1.swapEthForToken{value: ethAmount}(1, block.timestamp + 100000);
        vm.stopPrank();

        // getExpectedReturnForEth works
        assertEq(expectedReturn, tokensBought);

        (uint256 tokenBalanceAfter,) = memeExchange1.getUserBalances(signer3);
        // token balance is correctly incremented
        assertEq(tokenBalanceAfter, tokenBalanceBefore + tokensBought);

        // memeTokenSupplyinLiquidity is correctly updated
        (, uint256 memeTokenSupplyInLiquidityAfter,,) = memeExchange1.getLiquidityData();
        assertEq(memeTokenSupplyInLiquidityBefore, memeTokenSupplyInLiquidityAfter + tokensBought);
    }

    function testSwapEthForToken_ethBalances() public {
        uint256 ethAmount = 0.1 ether;
        uint256 ethBalanceBefore = memeExchange1.getReserveEth();

        address feeBenificiary = factory.getFeeBeneficiary();
        uint256 fbEthBalanceBefore = feeBenificiary.balance;

        (,,,, uint256 creatorFeesClaimableBefore,,) = memeExchange1.getExchangeMetadata();

        vm.startPrank(signer3);
        memeExchange1.swapEthForToken{value: ethAmount}(1, block.timestamp + 100000);
        vm.stopPrank();

        (,,,, uint256 creatorFeesClaimableAfter,, uint256 swapFee_) = memeExchange1.getExchangeMetadata();
        uint256 ethBalanceAfter = memeExchange1.getReserveEth();
        uint256 totalSwapFee = ethAmount * swapFee_ / 100000;
        uint256 ethToAdmin = totalSwapFee / 10; // 10% of fee to protocol
        uint256 ethToCreator = totalSwapFee / 10; // 10% of fee to creator
        assertEq(ethBalanceBefore + ethAmount, ethBalanceAfter + ethToCreator + ethToAdmin);

        assertEq(creatorFeesClaimableBefore + ethToCreator, creatorFeesClaimableAfter);

        uint256 fbEthBalanceAfter = feeBenificiary.balance;
        assertEq(fbEthBalanceAfter, fbEthBalanceBefore + ethToAdmin);
    }

    function testAddLiquidity() public {
        vm.startPrank(signer3);

        uint256 ethAmount = 0.01 ether;
        memeExchange1.swapEthForToken{value: ethAmount * 2}(1, block.timestamp + 100000);

        (, uint256 memeTokenSupplyLiqBefore, uint256 lpTokenSupplyBefore,) = memeExchange1.getLiquidityData();
        uint256 ethBalanceBefore = memeExchange1.getReserveEth();

        (uint256 tokenBalanceBefore, uint256 lpBalanceBefore) = memeExchange1.getUserBalances(signer3);

        uint256 tokenAmountForEthLiquidity = memeExchange1.getTokenAmountForEthLiquidity(ethAmount);
        memeExchange1.addLiquidity{value: ethAmount}(1, block.timestamp + 100000);

        (uint256 tokenBalanceAfter, uint256 lpBalanceAfter) = memeExchange1.getUserBalances(signer3);
        assertEq(tokenBalanceAfter + tokenAmountForEthLiquidity, tokenBalanceBefore);

        uint256 ethBalanceAfter = memeExchange1.getReserveEth();
        assertEq(ethBalanceAfter, ethBalanceBefore + ethAmount);

        (, uint256 memeTokenSupplyLiqAfter, uint256 lpTokenSupplyAfter,) = memeExchange1.getLiquidityData();
        uint256 expectedLpTokenBalance = ethAmount * lpTokenSupplyBefore / ethBalanceBefore;
        assertEq(expectedLpTokenBalance + lpTokenSupplyBefore, lpTokenSupplyAfter);

        assertEq(memeTokenSupplyLiqAfter, memeTokenSupplyLiqBefore + tokenAmountForEthLiquidity);
        assertEq(lpBalanceBefore + expectedLpTokenBalance, lpBalanceAfter);

        vm.stopPrank();
    }

    function testRemoveLiquidity() public {
        vm.startPrank(signer3);

        uint256 ethAmount = 0.01 ether;
        memeExchange1.swapEthForToken{value: ethAmount * 2}(1, block.timestamp + 100000);
        memeExchange1.addLiquidity{value: ethAmount}(1, block.timestamp + 100000);

        (uint256 tokenBalanceBefore, uint256 lpBalanceBefore) = memeExchange1.getUserBalances(signer3);
        uint256 contractEthBalanceBefore = memeExchange1.getReserveEth();

        uint256 liquidityToRemove = lpBalanceBefore / 2;
        (, uint256 memeTokenSupplyInLiquidityBefore, uint256 lpTokenSupplyBefore,) = memeExchange1.getLiquidityData();
        uint256 expectedEthRemoved = contractEthBalanceBefore * liquidityToRemove / lpTokenSupplyBefore;
        uint256 expectedTokenRemoved = memeTokenSupplyInLiquidityBefore * liquidityToRemove / lpTokenSupplyBefore;
        memeExchange1.removeLiquidity(liquidityToRemove, 1, 1, block.timestamp + 100);

        uint256 contractEthBalanceAfter = memeExchange1.getReserveEth();
        assertEq(contractEthBalanceAfter + expectedEthRemoved, contractEthBalanceBefore);

        (uint256 tokenBalanceAfter, uint256 lpBalanceAfter) = memeExchange1.getUserBalances(signer3);
        assertEq(lpBalanceAfter + liquidityToRemove, lpBalanceBefore);
        assertEq(tokenBalanceAfter, tokenBalanceBefore + expectedTokenRemoved);
    }

    function testRemoveOwnerLiquidity() public {
        vm.startPrank(signer3);
        uint256 ethAmount = 0.1 ether;
        memeExchange1.swapEthForToken{value: ethAmount * 2}(1, block.timestamp + 100000);
        memeExchange1.addLiquidity{value: ethAmount}(1, block.timestamp + 100000);
        vm.stopPrank();

        (
            uint256 poolOwnerStake,
            uint256 memeTokenSupplyInLiquidityBefore,
            uint256 lpTokenSupplyBefore,
            uint256 ethReserveBefore
        ) = memeExchange1.getLiquidityData();
        vm.startPrank(signer1);

        uint256 lpTokensToUnlock = poolOwnerStake / 2;
        vm.expectRevert();
        memeExchange1.removeOwnerLiquidity(lpTokensToUnlock, 1, 1);

        memeExchange1.startUnlockPeriodForOwnerLiquidity(lpTokensToUnlock);
        vm.warp(block.timestamp + ONE_WEEK + 1);

        vm.expectRevert();
        memeExchange1.removeOwnerLiquidity(lpTokensToUnlock + 1, 1, 1);

        (uint256 tokenBalanceBefore,) = memeExchange1.getUserBalances(signer1);
        (uint256 ethAmountWithdrawn, uint256 tokenAmountWithdrawn) =
            memeExchange1.removeOwnerLiquidity(lpTokensToUnlock, 1, 1);
        (uint256 tokenBalanceAfter,) = memeExchange1.getUserBalances(signer1);
        assertEq(tokenBalanceAfter, tokenBalanceBefore + tokenAmountWithdrawn);

        (
            uint256 poolOwnerStakeAfter,
            uint256 memeTokenSupplyInLiquidityAfter,
            uint256 lpTokenSupplyAfter,
            uint256 ethReserveAfter
        ) = memeExchange1.getLiquidityData();

        assertEq(poolOwnerStakeAfter + lpTokensToUnlock, poolOwnerStake);
        assertEq(memeTokenSupplyInLiquidityBefore, memeTokenSupplyInLiquidityAfter + tokenAmountWithdrawn);
        assertEq(lpTokenSupplyBefore, lpTokenSupplyAfter + lpTokensToUnlock);
        assertEq(ethReserveBefore, ethReserveAfter + ethAmountWithdrawn);

        vm.stopPrank();
    }

    function testLockMoreOwnerLiquidity() public {
        vm.startPrank(signer1);
        uint256 ethAmount = 0.1 ether;
        memeExchange1.swapEthForToken{value: ethAmount * 2}(1, block.timestamp + 100000);

        (
            uint256 poolOwnerStakeBefore,
            uint256 memeTokenSupplyLiqBefore,
            uint256 lpTokenSupplyBefore,
            uint256 reserveEthBefore
        ) = memeExchange1.getLiquidityData();
        uint256 tokenAmountForEthLiquidity = memeExchange1.getTokenAmountForEthLiquidity(ethAmount);
        uint256 liquidityMinted = memeExchange1.lockMoreOwnerLiquidity{value: ethAmount}(1, block.timestamp + 100);

        (uint256 poolOwnerStakeAfter, bool unlockInProgress,,) = memeExchange1.getOwnerLiquidityData();
        assertEq(unlockInProgress, false);
        assertEq(poolOwnerStakeBefore + liquidityMinted, poolOwnerStakeAfter);

        (, uint256 memeTokenSupplyLiqAfter, uint256 lpTokenSupplyAfter, uint256 reserveEthAfter) =
            memeExchange1.getLiquidityData();
        assertEq(memeTokenSupplyLiqAfter, memeTokenSupplyLiqBefore + tokenAmountForEthLiquidity);
        assertEq(lpTokenSupplyBefore + liquidityMinted, lpTokenSupplyAfter);
        assertEq(reserveEthBefore + ethAmount, reserveEthAfter);

        vm.stopPrank();
    }

    function testHook() public {
        vm.startPrank(signer3);

        HookMock hook = new HookMock();

          MemespaceFactory.CreateExchangeParams memory params = MemespaceFactory.CreateExchangeParams(
            "TEST", "Test Token", initialEthLiquidity, memeTokenSupply, swapFee, "", address(hook)
        );
        uint256 registrationFee = factory.getRegistrationFee("TEST");

        IMemespaceExchange memeExchange2 = IMemespaceExchange(factory.createExchange{value: initialEthLiquidity + registrationFee}(params));

        hook.setExchange(address(memeExchange2));

        vm.stopPrank();

        vm.startPrank(signer1);
        uint256 ethAmount = 0.01 ether;
        memeExchange2.swapEthForToken{value: ethAmount}(1, block.timestamp + 100000);
        uint256 points = hook.points(signer1);
        assert(points > 0);

        vm.stopPrank();
    }

    function genKeyPair(uint256 rand) internal view returns (address, uint256) {
        uint256 key = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, rand)));
        address addr = vm.addr(key);
        return (addr, key);
    }
}
