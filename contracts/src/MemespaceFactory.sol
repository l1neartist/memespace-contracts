// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./MemespaceExchange.sol";
import "./ERC20Wrapper.sol";
import "./interfaces/IMemes.sol";

contract MemespaceFactory {
    struct CreateExchangeParams {
        string tokenSymbol;
        string tokenName;
        uint256 initialLiquidity;
        uint256 tokenSupply;
        uint256 swapFee;
        string metadataUrl;
        address hookAddress; // optional, can be address(0)
    }

    event NewExchange(
        CreateExchangeParams params,
        address indexed exchange,
        address erc20Wrapper
    );

    event TokenEmission(address indexed exchange, address indexed receiver, uint256 amount);

    event MetadataSet(address indexed user, string metadata);

    error InvalidArguments(string message);

    error IncorrectEthProvided();

    error InvalidSender();

    address public feeBeneficiary;

    IMemes public memes;

    mapping(address => string) public userMetadataUrl;

    mapping(string => address) private _tokenSymbolToExchangeAddress;
    mapping(address => bool) private _isExchange;

    constructor(address _feeBeneficiary, address _memes) {
        require(_feeBeneficiary != address(0));
        feeBeneficiary = _feeBeneficiary;
        memes = IMemes(_memes);
    }

    function createExchange(CreateExchangeParams memory params) external payable returns (address) {
        string memory symbolUppercase = _toUpper(params.tokenSymbol);

        uint256 registrationFee = getRegistrationFee(symbolUppercase);

        if (
            bytes(symbolUppercase).length == 0 || bytes(symbolUppercase).length > 8
                || _tokenSymbolToExchangeAddress[symbolUppercase] != address(0)
        ) {
            revert InvalidArguments("Invalid tokenSymbol");
        }
        if (bytes(params.tokenName).length == 0 || bytes(params.tokenName).length > 24) {
            revert InvalidArguments("Invalid params.tokenName length");
        }

        if (msg.value != params.initialLiquidity + registrationFee) {
            revert IncorrectEthProvided();
        }

        MemespaceExchange exchange = new MemespaceExchange(
            symbolUppercase,
            params.tokenName,
            msg.sender,
            params.initialLiquidity,
            params.tokenSupply,
            params.swapFee,
            params.metadataUrl,
            params.hookAddress
        );

        address exchAddress = address(exchange);
        _tokenSymbolToExchangeAddress[symbolUppercase] = exchAddress;
        _isExchange[exchAddress] = true;

        (bool sent,) = exchAddress.call{value: msg.value - registrationFee}("");
        require(sent);
        (sent,) = feeBeneficiary.call{value: registrationFee}("");
        require(sent);

        ERC20Wrapper wrapper = new ERC20Wrapper(symbolUppercase, exchAddress);

        emit NewExchange(params, exchAddress, address(wrapper));
        return exchAddress;
    }

    function getRegistrationFee(string memory tokenSymbol) public pure returns (uint256) {
        uint256 length = bytes(tokenSymbol).length;
        if (length == 1) return 10 ether;
        if (length == 2) return 1 ether;
        if (length == 3) return 0.1 ether;
        return 0.01 ether;
    }

    function isSymbolAvailable(string memory tokenSymbol) public view returns (bool) {
        return _tokenSymbolToExchangeAddress[_toUpper(tokenSymbol)] == address(0);
    }

    function getExchangeAddressFromSymbol(string memory tokenSymbol) public view returns (address) {
        return _tokenSymbolToExchangeAddress[_toUpper(tokenSymbol)];
    }

    function getFeeBeneficiary() public view returns (address) {
        return feeBeneficiary;
    }

    function setFeeBeneficiary(address _feeBeneficiary) external {
        if (msg.sender != feeBeneficiary) {
            revert InvalidSender();
        }
        feeBeneficiary = _feeBeneficiary;
    }

    function generateToken(address recipient, uint256 amount) external {
        if (!_isExchange[msg.sender]) {
            revert InvalidSender();
        }
        memes.mint(recipient, amount);
        memes.mint(feeBeneficiary, amount);
        emit TokenEmission(msg.sender, recipient, amount);
        emit TokenEmission(msg.sender, feeBeneficiary, amount);
    }

    function setUserMetadataUrl(string memory metadataUrl) external {
        userMetadataUrl[msg.sender] = metadataUrl;
        emit MetadataSet(msg.sender, metadataUrl);
    }

    function _toUpper(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bUpper = new bytes(bStr.length);
        for (uint256 i = 0; i < bStr.length; i++) {
            // Lowercase character...
            if ((bStr[i] >= 0x61) && (bStr[i] <= 0x7A)) {
                // Subtract 32 to make it uppercase
                bUpper[i] = bytes1(uint8(bStr[i]) - 32);
            } else {
                bUpper[i] = bStr[i];
            }
        }
        return string(bUpper);
    }
}
