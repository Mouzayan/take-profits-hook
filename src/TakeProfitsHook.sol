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

Redeem Output Tokens Flow:
We need to store the amount of output tokens that are redeemable a specific position
The user has claim tokens equivalent to their input amount
We calculate their share of output tokens
Reduce that amount from the redeemable output tokens storage value
Burn their claim tokens
Transfer their output tokens to them
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

    // tracks the total supply of the minted claim tokens
    mapping(uint256 positionId => uint256 claimsSupply) public claimTokensSupply;

    // track output token amounts
    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;

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

    // Round down to the closest lower tick
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

    // Get user position id for ERC-1155 claim tokens issued to the order maker
    function getPositionId(
    PoolKey calldata key,
    int24 tick,
    bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function placeOrder(
    PoolKey calldata key,
    int24 tickToSellAt,
    bool zeroForOne,
    uint256 inputAmount
    ) external returns (int24) {
        // round given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        // Mint claim tokens to user equal to their `inputAmount`
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        // Return the tick at which the order was actually placed
        return tick;
    }

    // Delete the pending order from the mapping, burn the claim tokens,
    // reduce the claim token total supply, and send input tokens back to user
    // note: function does not take into account partial cancelations
    function cancelOrder(
    PoolKey calldata key,
    int24 tickToSellAt,
    bool zeroForOne,
    uint256 amountToCancel
    ) external {
        // Get tick for user order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // Get amount of claim tokens users are holding for this position
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < amountToCancel) revert NotEnoughToClaim();

        // Remove their `amountToCancel` worth of position from pending orders
        pendingOrders[key.toId()][tick][zeroForOne] -= amountToCancel;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[positionId] -= amountToCancel;
        _burn(msg.sender, positionId, amountToCancel);

        // Send their input token backk to the user
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, amountToCancel);
    }

    // Redeem output tokens
    function redeem(
    PoolKey calldata key,
    int24 tickToSellAt,
    bool zeroForOne,
    uint256 inputAmountToClaimFor
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        // they must have claim tokens >= inputAmountToClaimFor
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];

        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForPosition,
            totalInputAmountForPosition
        );

        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        // Transfer output tokens
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    function swapAndSettleBalances(
    PoolKey calldata key,
    IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, "");

        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }

    function executeOrder(
    PoolKey calldata key,
    int24 tick,
    bool zeroForOne,
    uint256 inputAmount
    ) internal {
        // Do the actual swap and settle all balances
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[positionId] += outputAmount;
    }
}