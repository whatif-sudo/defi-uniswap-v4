// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// import {console} from "forge-std/Test.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {CurrencyLib} from "../libraries/CurrencyLib.sol";

interface IDex {
    function swap(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut);
}

contract Flash is IUnlockCallback {
    using CurrencyLib for address;

    IPoolManager public immutable poolManager;
    address public owner;

    struct ArbParams {
        address currency;
        uint256 amount;
        address dexA;
        address dexB;
        address intermediateToken;
        uint256 minProfit;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
        owner = msg.sender;
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data)
        external
        onlyPoolManager
        returns (bytes memory)
    {
        ArbParams memory params = abi.decode(data, (ArbParams));

        // 1. Borrow flash loan
        poolManager.take({
            currency: params.currency,
            to: address(this),
            amount: params.amount
        });

        uint256 balanceBefore = params.currency == address(0) 
            ? address(this).balance 
            : IERC20(params.currency).balanceOf(address(this));

        // 2. Execute arbitrage logic
        // Step A: Swap currency -> intermediateToken on DexA
        uint256 intermediateAmount;
        if (params.currency == address(0)) {
            // Handle native currency
            intermediateAmount = IDex(params.dexA).swap{value: params.amount}(
                params.currency,
                params.intermediateToken,
                params.amount
            );
        } else {
            // Approve and swap ERC20
            IERC20(params.currency).approve(params.dexA, params.amount);
            intermediateAmount = IDex(params.dexA).swap(
                params.currency,
                params.intermediateToken,
                params.amount
            );
        }

        // Step B: Swap intermediateToken -> currency on DexB
        IERC20(params.intermediateToken).approve(params.dexB, intermediateAmount);
        uint256 finalAmount = IDex(params.dexB).swap(
            params.intermediateToken,
            params.currency,
            intermediateAmount
        );

        uint256 balanceAfter = params.currency == address(0)
            ? address(this).balance
            : IERC20(params.currency).balanceOf(address(this));

        // 3. Verify profit
        uint256 profit = balanceAfter - balanceBefore + params.amount;
        require(profit >= params.minProfit, "Insufficient profit");

        // 4. Repay flash loan
        poolManager.sync(params.currency);

        if (params.currency == address(0)) {
            poolManager.settle{value: params.amount}();
        } else {
            IERC20(params.currency).transfer(address(poolManager), params.amount);
            poolManager.settle();
        }

        // 5. Transfer profit to owner
        if (params.currency == address(0)) {
            payable(owner).transfer(profit);
        } else {
            IERC20(params.currency).transfer(owner, profit);
        }

        return "";
    }

    function executeArbitrage(
        address currency,
        uint256 amount,
        address dexA,
        address dexB,
        address intermediateToken,
        uint256 minProfit
    ) external onlyOwner {
        ArbParams memory params = ArbParams({
            currency: currency,
            amount: amount,
            dexA: dexA,
            dexB: dexB,
            intermediateToken: intermediateToken,
            minProfit: minProfit
        });

        poolManager.unlock(abi.encode(params));
    }

    // withdraw function
    function withdraw(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner).transfer(address(this).balance);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            IERC20(token).transfer(owner, balance);
        }
    }

    // Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }
}
