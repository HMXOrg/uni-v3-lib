// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.4;

import "./SqrtPriceMath.sol";

/// @title Computes the result of a swap within ticks
/// @author Aperture Finance
/// @author Modified from Uniswap (https://github.com/uniswap/v3-core/blob/main/contracts/libraries/SwapMath.sol)
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    uint256 internal constant MAX_FEE_PIPS = 1e6;

    /// @notice Computes the sqrt price target for the next swap step
    /// @param zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0
    /// @param sqrtPriceNextX96 The Q64.96 sqrt price for the next initialized tick
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this
    /// value after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// @return sqrtRatioTargetX96 The price target for the next swap step
    function getSqrtRatioTarget(
        bool zeroForOne,
        uint160 sqrtPriceNextX96,
        uint160 sqrtPriceLimitX96
    ) internal pure returns (uint160 sqrtRatioTargetX96) {
        assembly {
            // a flag to toggle between sqrtPriceNextX96 and sqrtPriceLimitX96
            // when zeroForOne == true, nextOrLimit reduces to sqrtPriceNextX96 > sqrtPriceLimitX96
            // sqrtRatioTargetX96 = max(sqrtPriceNextX96, sqrtPriceLimitX96)
            // when zeroForOne == false, nextOrLimit reduces to sqrtPriceNextX96 <= sqrtPriceLimitX96
            // sqrtRatioTargetX96 = min(sqrtPriceNextX96, sqrtPriceLimitX96)
            let nextOrLimit := xor(gt(sqrtPriceNextX96, sqrtPriceLimitX96), iszero(zeroForOne))
            let symDiff := xor(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtRatioTargetX96 := xor(sqrtPriceLimitX96, mul(symDiff, nextOrLimit))
        }
    }

    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        unchecked {
            bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
            uint256 feeComplement = MAX_FEE_PIPS - feePips;
            bool exactOut;
            uint256 amountRemainingAbs;
            assembly {
                // exactOut = 1 if amountRemaining < 0 else 0
                exactOut := slt(amountRemaining, 0)
                // mask = -1 if amountRemaining < 0 else 0
                let mask := sub(0, exactOut)
                amountRemainingAbs := xor(mask, add(mask, amountRemaining))
            }

            if (!exactOut) {
                uint256 amountRemainingLessFee = FullMath.mulDiv(amountRemainingAbs, feeComplement, MAX_FEE_PIPS);
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
                if (amountRemainingLessFee >= amountIn) {
                    // `amountIn` is capped by the target price
                    sqrtRatioNextX96 = sqrtRatioTargetX96;
                    feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, feeComplement);
                } else {
                    // exhaust the remaining amount
                    amountIn = amountRemainingLessFee;
                    sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                        sqrtRatioCurrentX96,
                        liquidity,
                        amountIn,
                        zeroForOne
                    );
                    // we didn't reach the target, so take the remainder of the maximum input as fee
                    feeAmount = amountRemainingAbs - amountIn;
                }
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false)
                    : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
            } else {
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                    : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
                if (amountRemainingAbs >= amountOut) {
                    // `amountOut` is capped by the target price
                    sqrtRatioNextX96 = sqrtRatioTargetX96;
                } else {
                    // cap the output amount to not exceed the remaining output amount
                    amountOut = amountRemainingAbs;
                    sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                        sqrtRatioCurrentX96,
                        liquidity,
                        amountOut,
                        zeroForOne
                    );
                }
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
                feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, feeComplement);
            }
        }
    }

    /// @notice Computes the result of swapping some amount in given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input amount is remaining to be swapped in
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    function computeSwapStepExactIn(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        uint256 amountRemaining,
        uint256 feePips
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut) {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        uint256 feeComplement = UnsafeMath.sub(MAX_FEE_PIPS, feePips);
        uint256 amountRemainingLessFee = FullMath.mulDiv(amountRemaining, feeComplement, MAX_FEE_PIPS);
        amountIn = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
        if (amountRemainingLessFee >= amountIn) {
            // `amountIn` is capped by the target price
            sqrtRatioNextX96 = sqrtRatioTargetX96;
            // add the fee amount
            amountIn = FullMath.mulDivRoundingUp(amountIn, MAX_FEE_PIPS, feeComplement);
        } else {
            // exhaust the remaining amount
            amountIn = amountRemaining;
            sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                sqrtRatioCurrentX96,
                liquidity,
                amountRemainingLessFee,
                zeroForOne
            );
        }
        amountOut = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
    }

    /// @notice Computes the result of swapping some amount out, given the parameters of the swap
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much output amount is remaining to be swapped out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    function computeSwapStepExactOut(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        uint256 amountRemaining,
        uint256 feePips
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut) {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        amountOut = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
        if (amountRemaining >= amountOut) {
            // `amountOut` is capped by the target price
            sqrtRatioNextX96 = sqrtRatioTargetX96;
        } else {
            // cap the output amount to not exceed the remaining output amount
            amountOut = amountRemaining;
            sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                sqrtRatioCurrentX96,
                liquidity,
                amountRemaining,
                zeroForOne
            );
        }
        amountIn = FullMath.mulDivRoundingUp(
            zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true),
            MAX_FEE_PIPS,
            UnsafeMath.sub(MAX_FEE_PIPS, feePips)
        );
    }
}
