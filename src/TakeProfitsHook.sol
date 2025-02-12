// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/**
A take-profit is a type of order where the user wants to sell a token once it's price increases
to hit a certain price.

At a very high level we will need for sure:
Ability to place an order
Ability to cancel an order after placing (if not filled yet)
Ability to withdraw/redeem tokens after order is filled

A tick of 600 means that the logarithmic price ratio is greater than zero, indicating that
Token 0 (A) is more valuable than Token 1 (B).
• The higher the tick, the lower the price of Token 1 (B) in terms of Token 0 (A), or
equivalently, the higher the price of Token 0 (A) in terms of Token 1 (B).

We will have our hook be an ERC-1155 contract so we can issue "claim" tokens to the users proportional
to how many input tokens they provided for their order, and will use that to calculate how many output
tokens they have available to claim.

User Placing Order Flow:
Users specify which pool to place the order for, what tick to sell their tokens at,
which direction the swap is happening, and how many tokens to sell
Users may specify any arbitrary tick, pick the closest actual usable tick based on
the tick spacing of the pool - rounding down by default.
Save user order info in storage.
Mint "claim" tokens to users so they can claim output tokens that uniquely represent
their order parameters.
Transfer the input tokens from user wallets to the hook contract.
 */

contract TakeProfitsHook is BaseHook, ERC1155 {
	// Adds helper functions to the PoolManager to read
	// storage values. Used for accessing `currentTick`
	// values from the pool manager
	using StateLibrary for IPoolManager;
	// Converts PoolKeys to IDs
	using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

	// Errors
	error InvalidOrder();
	error NothingToClaim();
	error NotEnoughToClaim();

    // State
    // mapping to store pending orders to identify user positions
    mapping(PoolId poolId =>
	    mapping(int24 tickToSellAt =>
		    mapping(bool zeroForOne => uint256 inputAmount)
        )
    ) public pendingOrders;

    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

	// baseHook Functions
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override onlyPoolManager returns (bytes4) {
		// TODO
        return this.afterInitialize.selector;
    }

	function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
		// TODO
        return (this.afterSwap.selector, 0);
    }

    // Round down to the closest lower tick usable
    function getLowerUsableTick(
    int24 tick,
    int24 tickSpacing
    ) private pure returns (int24) {
        // E.g. tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120

        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;

        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity

        // actual usable tick, then, is intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return intervals * tickSpacing;
    }
}