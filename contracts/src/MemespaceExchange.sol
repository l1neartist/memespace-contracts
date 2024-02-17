// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./interfaces/IMemespaceFactory.sol";
import "./interfaces/IHook.sol";
import "./interfaces/IBlast.sol";

contract MemespaceExchange {
    IMemespaceFactory public factory;

    string private _tokenSymbol;
    string private _tokenName;
    address private _poolOwner;
    uint256 private immutable _memeTokenTotalSupply;

    uint256 private _poolOwnerStake;
    uint256 private _ownerRoyaltiesClaimable;

    uint256 private _memeTokenSupplyInLiquidity;
    uint256 private _lpTokenSupply;

    uint256 private immutable _swapFee;

    string private _metadataUrl;

    // owner and protocol each earn 10% of swap fee
    uint256 public constant FEE_DIVISOR = 10;

    // owner allocates 10% of supply at launch, 
    // remaining 90% locked in owner liquidity
    uint256 public constant OWNER_INITIAL_TOKEN_SHARE_DIVISOR = 10;

    uint256 public constant UNLOCK_PERIOD = 1 weeks;

    uint256 public constant MIN_SWAP_FEE = 100; // 0.1%
    uint256 public constant MAX_SWAP_FEE = 5000; // 5%
    uint256 public constant SWAP_FEE_SCALE = 100000; // 100%

    // todo: on mainnet, will be dynamically decreasing
    uint256 public constant TOKEN_ROYALTIES_MULTIPLIER = 1000;

    uint256 public constant INITIAL_LP_SUPPLY_MULTIPLIER = 1000;

    mapping(address => uint256) private _tokenBalance;
    mapping(address => uint256) private _lpTokenBalance;

    address private _hookAddress;

    IBlast blastYield = IBlast(0x4300000000000000000000000000000000000002);

    struct UnlockStatus {
        bool unlockPeriodInProgress;
        uint256 unlockPeriodStart;
        uint256 lpTokensToUnlock;
    }

    UnlockStatus private _unlockStatus;

    // price > 0 means exchange is for sale
    uint256 public exchangeForSalePrice = 0;

    event TokensBought(address indexed buyer, uint256 ethInput, uint256 tokenOutput);
    event TokensSold(address indexed seller, uint256 tokenInput, uint256 ethOutput);
    event LiquidityAdded(address indexed lp, uint256 ethAdded, uint256 tokenAdded, uint256 liquidityMinted);
    event LiquidityRemoved(address indexed lp, uint256 ethRemoved, uint256 tokenRemoved, uint256 liquidityBurned);
    event UnlockPeriodStarted(uint256 startTimestamp, uint256 lpTokensUnlocking);
    event OwnerLiquidityAdded(uint256 ethAmount, uint256 tokenAmount, uint256 liquidityMinted, address owner);
    event OwnerLiquidityRemoved(uint256 ethAmount, uint256 tokenAmount, uint256 liquidityBurned, address owner);
    event SwapFeeGenerated(address indexed trader, uint256 ethAmount, string tradeType);
    event RoyaltiesGenerated(uint256 ethAmount);
    event RoyaltiesClaimed(uint256 ethAmount);
    event MetadataSet(string metadataUrl);
    event GasClaimed(uint256 ethAmount);
    event ExchangeListed(uint256 ethAmount);
    event ExchangeDelisted();

    error InvalidSender();
    error InvalidArguments(string message);
    error InvalidTiming(string message);

    constructor(
        string memory tokenSymbol,
        string memory tokenName,
        address poolOwner,
        uint256 initialEth,
        uint256 tokenSupply,
        uint256 swapFee,
        string memory metadataUrl,
        address hookAddress
    ) {
        require(address(factory) == address(0));
        factory = IMemespaceFactory(msg.sender);
        _tokenSymbol = tokenSymbol;
        _tokenName = tokenName;
        _poolOwner = poolOwner;
        _memeTokenTotalSupply = tokenSupply;

        if (swapFee < MIN_SWAP_FEE || swapFee > MAX_SWAP_FEE) {
            revert InvalidArguments("Invalid swap fee");
        }
        _swapFee = swapFee;

        uint256 ownerInitialTokenShare = tokenSupply / OWNER_INITIAL_TOKEN_SHARE_DIVISOR;
        uint256 initialMemeTokenSupplyInLiquidity = tokenSupply - ownerInitialTokenShare;
        _memeTokenSupplyInLiquidity = initialMemeTokenSupplyInLiquidity;
        _tokenBalance[poolOwner] += ownerInitialTokenShare;

        _metadataUrl = metadataUrl;
        emit MetadataSet(metadataUrl);

        _hookAddress = hookAddress;

        uint256 liquidityMinted = initialEth * INITIAL_LP_SUPPLY_MULTIPLIER;
        _poolOwnerStake = liquidityMinted;

        _lpTokenSupply = liquidityMinted;
        _lpTokenBalance[poolOwner] += liquidityMinted;

        emit OwnerLiquidityAdded(initialEth, initialMemeTokenSupplyInLiquidity, liquidityMinted, poolOwner);

        _interact(poolOwner, IHook.Interaction.ADD_LIQUIDITY, liquidityMinted, initialEth, initialMemeTokenSupplyInLiquidity);

        blastYield.configureAutomaticYield();
        blastYield.configureClaimableGas();
    }

    function claimAllGas() public {
        uint256 ethBefore = address(this).balance;
        blastYield.claimAllGas(address(this), address(this));
        uint256 ethAfter = address(this).balance;
        emit GasClaimed(ethAfter - ethBefore);
    }

    function swapEthForToken(uint256 minTokens, uint256 deadline) external payable returns (uint256 tokensBought) {
        if (minTokens == 0) {
            revert InvalidArguments("Must pass min amount");
        }
        if (msg.value == 0) {
            revert InvalidArguments("Must provide ETH");
        }
        if (deadline < block.timestamp) {
            revert InvalidTiming("Deadline has passed");
        }
        uint256 fee = msg.value * _swapFee / SWAP_FEE_SCALE;

        tokensBought = getInputPrice(msg.value - fee, getReserveEth() - msg.value, _memeTokenSupplyInLiquidity);
        if (tokensBought < minTokens) {
            revert InvalidArguments("Insufficient swap return");
        }

        _tokenBalance[msg.sender] += tokensBought;
        _memeTokenSupplyInLiquidity -= tokensBought;

        (bool sent,) = factory.getFeeBeneficiary().call{value: fee / FEE_DIVISOR}("");
        require(sent);

        uint256 ownerRoyalties = fee / FEE_DIVISOR;
        _ownerRoyaltiesClaimable += ownerRoyalties;

        _interact(msg.sender, IHook.Interaction.SWAP_IN, 0, msg.value, tokensBought);
        emit TokensBought(msg.sender, msg.value, tokensBought);
        emit SwapFeeGenerated(msg.sender, fee, "BUY");
        emit RoyaltiesGenerated(ownerRoyalties);
    }

    function swapTokenForEth(uint256 tokensToSell, uint256 minEth, uint256 deadline)
        external
        returns (uint256 ethOutput)
    {
        if (tokensToSell > _tokenBalance[msg.sender]) {
            revert InvalidArguments("Insufficient token balance");
        }
        if (deadline < block.timestamp) {
            revert InvalidTiming("Deadline has passed");
        }
        if (minEth == 0) {
            revert InvalidArguments("Must pass min amount");
        }
        if (tokensToSell == 0) {
            revert InvalidArguments("Must pass token amount");
        }

        ethOutput = getInputPrice(tokensToSell, _memeTokenSupplyInLiquidity, getReserveEth());

        uint256 fee = ethOutput * _swapFee / SWAP_FEE_SCALE;
        ethOutput -= fee;
        if (minEth > ethOutput) {
            revert InvalidArguments("Insufficient swap return");
        }

        _tokenBalance[msg.sender] -= tokensToSell;
        _memeTokenSupplyInLiquidity += tokensToSell;

        (bool sent,) = factory.getFeeBeneficiary().call{value: fee / FEE_DIVISOR}("");
        require(sent);
        (sent,) = msg.sender.call{value: ethOutput}("");
        require(sent);

        uint256 ownerRoyalties = fee / FEE_DIVISOR;
        _ownerRoyaltiesClaimable += ownerRoyalties;

        _interact(msg.sender, IHook.Interaction.SWAP_OUT, 0, ethOutput, tokensToSell);
        emit TokensSold(msg.sender, tokensToSell, ethOutput);
        emit SwapFeeGenerated(msg.sender, fee, "SELL");
        emit RoyaltiesGenerated(ownerRoyalties);
    }

    function addLiquidity(uint256 minLpTokens, uint256 deadline) external payable returns (uint256 liquidityMinted) {
        if (_lpTokenSupply == 0) {
            revert InvalidArguments("Pool uninitiated");
        }
        if (minLpTokens == 0) {
            revert InvalidArguments("Must pass min amount");
        }
        if (deadline < block.timestamp) {
            revert InvalidTiming("Deadline has passed");
        }
        if (msg.value == 0) {
            revert InvalidArguments("Must provide ETH");
        }

        uint256 ethReserve = getReserveEth() - msg.value;

        uint256 tokenAmount = (msg.value * _memeTokenSupplyInLiquidity / ethReserve) + 1;
        if (tokenAmount > _tokenBalance[msg.sender]) {
            revert InvalidArguments("Insufficient token balance");
        }

        _tokenBalance[msg.sender] -= tokenAmount;
        _memeTokenSupplyInLiquidity += tokenAmount;

        liquidityMinted = msg.value * _lpTokenSupply / ethReserve;
        if (liquidityMinted < minLpTokens) {
            revert InvalidArguments("Insufficient LP return");
        }
        _lpTokenSupply += liquidityMinted;
        _lpTokenBalance[msg.sender] += liquidityMinted;

        _interact(msg.sender, IHook.Interaction.ADD_LIQUIDITY, liquidityMinted, msg.value, tokenAmount);

        emit LiquidityAdded(msg.sender, msg.value, tokenAmount, liquidityMinted);
    }

    function removeLiquidity(
        uint256 lpTokensToBurn,
        uint256 minEthWithdrawn,
        uint256 minTokensWithdrawn,
        uint256 deadline
    ) external returns (uint256 ethAmount, uint256 tokenAmount) {
        if (lpTokensToBurn > _lpTokenBalance[msg.sender]) {
            revert InvalidArguments("Insufficient token balance");
        }
        if (_poolOwner == msg.sender) {
            // must use unlockPeriod functions for _poolOwnerStake
            if (lpTokensToBurn + _poolOwnerStake > _lpTokenBalance[_poolOwner]) {
                revert InvalidArguments("Insufficient unlocked liquidity");
            }
        }
        if (lpTokensToBurn == 0 || minEthWithdrawn == 0) {
            revert InvalidArguments("Must pass min amounts");
        }
        if (deadline < block.timestamp) {
            revert InvalidTiming("Deadline has passed");
        }

        ethAmount = lpTokensToBurn * getReserveEth() / _lpTokenSupply;
        tokenAmount = lpTokensToBurn * _memeTokenSupplyInLiquidity / _lpTokenSupply;
        if (ethAmount < minEthWithdrawn || tokenAmount < minTokensWithdrawn) {
            revert InvalidArguments("Insufficient LP return");
        }

        _memeTokenSupplyInLiquidity -= tokenAmount;
        _tokenBalance[msg.sender] += tokenAmount;

        _lpTokenBalance[msg.sender] -= lpTokensToBurn;
        _lpTokenSupply -= lpTokensToBurn;

        (bool sent,) = msg.sender.call{value: ethAmount}("");
        require(sent);

        _interact(msg.sender, IHook.Interaction.REMOVE_LIQUIDITY, lpTokensToBurn, ethAmount, tokenAmount);
        emit LiquidityRemoved(msg.sender, ethAmount, tokenAmount, lpTokensToBurn);
    }

    function transferExchangeOwnership(address _newOwner) public {
        if (_poolOwner != msg.sender) {
            revert InvalidSender();
        }
        _transferExchangeOwnership(_newOwner);
    }

    function _transferExchangeOwnership(address _newOwner) private {
        if (_newOwner == address(0)) {
            revert InvalidArguments("Must pass address");
        }
        _lpTokenBalance[_newOwner] += _poolOwnerStake;
        _lpTokenBalance[_poolOwner] -= _poolOwnerStake;
        _poolOwner = _newOwner;
    }

    function startUnlockPeriodForOwnerLiquidity(uint256 lpTokensToUnlock) external {
        if (_poolOwner != msg.sender) {
            revert InvalidSender();
        }
        if (lpTokensToUnlock > _poolOwnerStake) {
            revert InvalidArguments("Insufficient owner stake");
        }
        if (_unlockStatus.unlockPeriodInProgress == true) {
            revert InvalidTiming("Unlock period ongoing");
        }
        _unlockStatus.lpTokensToUnlock = lpTokensToUnlock;
        _unlockStatus.unlockPeriodInProgress = true;
        _unlockStatus.unlockPeriodStart = block.timestamp;

        emit UnlockPeriodStarted(block.timestamp, lpTokensToUnlock);
    }

    function lockMoreOwnerLiquidity(uint256 minLpTokens, uint256 deadline)
        external
        payable
        returns (uint256 liquidityMinted)
    {
        if (_poolOwner != msg.sender) {
            revert InvalidSender();
        }
        if (minLpTokens == 0) {
            revert InvalidArguments("Must pass min amount");
        }
        if (deadline < block.timestamp) {
            revert InvalidTiming("Deadline has passed");
        }
        if (msg.value == 0) {
            revert InvalidArguments("Must provide ETH");
        }
        _unlockStatus.unlockPeriodInProgress = false;

        uint256 ethReserve = getReserveEth() - msg.value;
        uint256 tokenAmount = (msg.value * _memeTokenSupplyInLiquidity / ethReserve) + 1;
        if (tokenAmount > _tokenBalance[_poolOwner]) {
            revert InvalidArguments("Insufficient token balance");
        }

        _tokenBalance[msg.sender] -= tokenAmount;
        _memeTokenSupplyInLiquidity += tokenAmount;

        liquidityMinted = msg.value * _lpTokenSupply / ethReserve;
        if (liquidityMinted < minLpTokens) {
            revert InvalidArguments("Insufficient LP return");
        }

        _lpTokenSupply += liquidityMinted;
        _lpTokenBalance[msg.sender] += liquidityMinted;
        _poolOwnerStake += liquidityMinted;

        _interact(msg.sender, IHook.Interaction.ADD_LIQUIDITY, liquidityMinted, msg.value, tokenAmount);
        emit OwnerLiquidityAdded(msg.value, tokenAmount, liquidityMinted, msg.sender);
    }

    function removeOwnerLiquidity(uint256 lpTokensToBurn, uint256 minEthWithdrawn, uint256 minTokensWithdrawn)
        external
        returns (uint256 ethAmount, uint256 tokenAmount)
    {
        if (_poolOwner != msg.sender) {
            revert InvalidSender();
        }
        if (lpTokensToBurn > _poolOwnerStake) {
            revert InvalidArguments("Insufficient owner stake");
        }
        if (lpTokensToBurn > _unlockStatus.lpTokensToUnlock) {
            revert InvalidArguments("Insufficient unlocked stake");
        }
        if (_unlockStatus.unlockPeriodInProgress == false) {
            revert InvalidTiming("Not unlock period");
        }
        if (_unlockStatus.unlockPeriodStart + UNLOCK_PERIOD > block.timestamp) {
            revert InvalidTiming("Unlock period elapsed");
        }

        _poolOwnerStake -= lpTokensToBurn;
        _unlockStatus.unlockPeriodInProgress = false;

        ethAmount = lpTokensToBurn * getReserveEth() / _lpTokenSupply;
        tokenAmount = lpTokensToBurn * _memeTokenSupplyInLiquidity / _lpTokenSupply;
        if (ethAmount < minEthWithdrawn || tokenAmount < minTokensWithdrawn) {
            revert InvalidArguments("Insufficient LP return");
        }

        _lpTokenSupply -= lpTokensToBurn;
        _memeTokenSupplyInLiquidity -= tokenAmount;
        _tokenBalance[_poolOwner] += tokenAmount;

        (bool sent,) = _poolOwner.call{value: ethAmount}("");
        require(sent);

        _interact(msg.sender, IHook.Interaction.REMOVE_LIQUIDITY, lpTokensToBurn, ethAmount, tokenAmount);
        emit OwnerLiquidityRemoved(ethAmount, tokenAmount, lpTokensToBurn, msg.sender);
    }

    function setExchangeSalePrice(uint256 ethPrice) external {
        if (_poolOwner != msg.sender) {
            revert InvalidSender();
        }
        if (ethPrice == 0) {
            emit ExchangeDelisted();
        } else {
            emit ExchangeListed(ethPrice);
        }
        exchangeForSalePrice = ethPrice;
    }

    function buyExchange() external payable {
        if (exchangeForSalePrice == 0) {
            revert InvalidTiming("Exchange not for sale");
        }
        if (msg.value != exchangeForSalePrice) {
            revert InvalidArguments("Incorrect value sent");
        }
        uint256 fee = msg.value / FEE_DIVISOR;
        (bool sent,) = _poolOwner.call{value: msg.value - fee}("");
        require(sent);
        (sent,) = factory.getFeeBeneficiary().call{value: fee}("");
        require(sent);
        exchangeForSalePrice = 0;
        _transferExchangeOwnership(msg.sender);
    }

    function claimOwnerRoyalties() external returns (uint256 ownerRoyalties) {
        if (_ownerRoyaltiesClaimable == 0) {
            revert InvalidTiming("No royalties available");
        }

        ownerRoyalties = _ownerRoyaltiesClaimable;
        _ownerRoyaltiesClaimable = 0;

        (bool sent,) = _poolOwner.call{value: ownerRoyalties}("");
        require(sent);

        factory.generateToken(_poolOwner, ownerRoyalties * TOKEN_ROYALTIES_MULTIPLIER);

        emit RoyaltiesClaimed(ownerRoyalties);
    }

    function setMetadataUrl(string memory metadataUrl) external {
        if (_poolOwner != msg.sender) {
            revert InvalidSender();
        }
        _metadataUrl = metadataUrl;
        emit MetadataSet(metadataUrl);
    }

    function setHookAddress(address _hook) external {
        if (_poolOwner != msg.sender) {
            revert InvalidSender();
        }
        _hookAddress = _hook;
    }

    receive() external payable {}

    function _interact(address user, IHook.Interaction interaction, uint256 lpAmount, uint256 ethAmount, uint256 tokenAmount) private {
        if (_hookAddress != address(0)) {
            try IHook(_hookAddress).interact(user, interaction, lpAmount, ethAmount, tokenAmount) {} catch {}
        }
    }

    function getTokenAmountForEthLiquidity(uint256 ethToDeposit) public view returns (uint256) {
        uint256 ethReserve = getReserveEth();
        return (ethToDeposit * _memeTokenSupplyInLiquidity / ethReserve) + 1;
    }

    function getExpectedReturnForEth(uint256 ethAmount) public view returns (uint256 tokenOutput) {
        return getInputPrice(
            ethAmount - (ethAmount * _swapFee / SWAP_FEE_SCALE), getReserveEth(), _memeTokenSupplyInLiquidity
        );
    }

    function getExpectedReturnForToken(uint256 tokenAmount) public view returns (uint256 ethOutput) {
        uint256 baseOutput = getInputPrice(tokenAmount, _memeTokenSupplyInLiquidity, getReserveEth());
        ethOutput = baseOutput - (baseOutput * _swapFee / SWAP_FEE_SCALE);
    }

    function getInputPrice(uint256 inputAmount, uint256 inputReserve, uint256 outputReserve)
        public
        pure
        returns (uint256)
    {
        require(inputReserve > 0 && outputReserve > 0, "Invalid values");
        uint256 numerator = inputAmount * outputReserve;
        uint256 denominator = (inputReserve) + (inputAmount);
        return numerator / denominator;
    }

    function getExchangeMetadata()
        external
        view
        returns (string memory, string memory, address, uint256, uint256, string memory, uint256)
    {
        return (
            _tokenSymbol,
            _tokenName,
            _poolOwner,
            _memeTokenTotalSupply,
            _ownerRoyaltiesClaimable,
            _metadataUrl,
            _swapFee
        );
    }

    function getLiquidityData() external view returns (uint256, uint256, uint256, uint256) {
        return (_poolOwnerStake, _memeTokenSupplyInLiquidity, _lpTokenSupply, getReserveEth());
    }

    function getOwnerLiquidityData() external view returns (uint256, bool, uint256, uint256) {
        return (
            _poolOwnerStake,
            _unlockStatus.unlockPeriodInProgress,
            _unlockStatus.unlockPeriodStart,
            _unlockStatus.lpTokensToUnlock
        );
    }

    function getUserBalances(address user) external view returns (uint256, uint256) {
        return (_tokenBalance[user], _lpTokenBalance[user]);
    }

    function getReserveEth() public view returns (uint256) {
        return address(this).balance - _ownerRoyaltiesClaimable;
    }
}
