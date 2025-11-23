// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

// Interfaz mínima de ERC4626 para el Mock
interface IERC4626 is IERC20 {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
}

contract MockERC4626 is IERC4626 {
    IERC20 public immutable assetToken;
    string public name;
    string public symbol;
    uint8 public decimals;
    
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(IERC20 _asset, string memory _name, string memory _symbol) {
        assetToken = _asset;
        name = _name;
        symbol = _symbol;
        // Try to get decimals, default to 18 if fails (mock logic)
        try MockERC20(address(_asset)).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            decimals = 18;
        }
    }

    // --- ERC20 Logic ---
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // --- ERC4626 Logic ---
    function asset() external view returns (address) { return address(assetToken); }
    
    function totalAssets() public view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets; // 1:1 ratio for simplicity
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares; // 1:1 ratio
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(assetToken.transferFrom(msg.sender, address(this), assets), "Transfer failed");
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        if (msg.sender != owner) {
             if (allowance[owner][msg.sender] != type(uint256).max) allowance[owner][msg.sender] -= shares;
        }
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(assetToken.transfer(receiver, assets), "Transfer failed");
    }
}

interface MockERC20 {
    function decimals() external view returns (uint8);
}
