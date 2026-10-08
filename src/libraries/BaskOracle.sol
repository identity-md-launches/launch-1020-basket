// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaskTypes as T} from "../BaskTypes.sol";
import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";

/// @dev Fixed-size return buffers prevent malicious returndata from growing caller memory.
library BaskOracle {
    error InvalidOracle();

    function read(address target, bytes memory input, uint256 gasLimit, uint256 size)
        internal
        view
        returns (bool ok, bytes memory output)
    {
        output = new bytes(size);
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 32), mload(input), add(output, 32), size)
            ok := and(ok, iszero(lt(returndatasize(), size)))
        }
    }

    function word(address target, bytes memory input, uint256 gasLimit)
        internal
        view
        returns (bool ok, uint256 result)
    {
        bytes memory output;
        (ok, output) = read(target, input, gasLimit, 32);
        assembly ("memory-safe") { result := mload(add(output, 32)) }
    }

    function decimals(address target, uint256 gasLimit) internal view returns (uint8) {
        (bool ok, uint256 d) = word(target, abi.encodeWithSignature("decimals()"), gasLimit);
        if (!ok || d > 18) revert InvalidOracle();
        return uint8(d);
    }

    function balance(address token, uint256 gasLimit) internal view returns (bool ok, uint256 result) {
        // Scratch memory avoids per-asset allocation in the worst-case redemption loop.
        // Copy exactly one word, including when upgraded code returns a large blob.
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x70a08231))
            mstore(4, address())
            ok := staticcall(gasLimit, token, 0, 36, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            result := mload(0)
        }
    }

    function feed(address target, uint256 gasLimit, uint256 maxAge)
        internal
        view
        returns (bool ok, uint256 answer, uint256 updatedAt)
    {
        bytes memory output;
        (ok, output) = read(target, abi.encodeWithSignature("latestRoundData()"), gasLimit, 160);
        int256 signedAnswer;
        assembly ("memory-safe") {
            signedAnswer := mload(add(output, 64))
            updatedAt := mload(add(output, 128))
        }
        if (signedAnswer > 0) answer = uint256(signedAnswer);
        ok = ok && answer != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge;
    }

    function value(uint256 amount, uint256 answer, uint8 tokenDecimals, uint8 feedDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 d = uint256(tokenDecimals) + feedDecimals;
        if (d >= 18) return FullMath.mulDiv(amount, answer, 10 ** (d - 18));
        return FullMath.mulDiv(amount, answer, 1) * 10 ** (18 - d);
    }

    function price(T.Asset memory a, T.Settings memory s)
        internal
        view
        returns (T.Reason reason, uint256 answer, uint256 updatedAt, uint256 poolPrice)
    {
        bool ok;
        (ok, answer, updatedAt) = feed(a.feed, s.feedGas, s.maxAge);
        if (!ok) return (T.Reason.Feed, answer, updatedAt, 0);
        // Compare the upper bound without overflowing centre * band.
        if (
            answer < a.centre / s.band || (answer / s.band > a.centre)
                || (answer / s.band == a.centre && answer % s.band != 0)
        ) {
            return (T.Reason.Band, answer, updatedAt, 0);
        }
        if (a.hasPause) {
            uint256 paused;
            (ok, paused) = word(a.token, abi.encodeWithSignature("oraclePaused()"), s.pauseGas);
            if (!ok || paused != 0) return (T.Reason.OraclePaused, answer, updatedAt, 0);
        }
        if (a.pool == address(0)) {
            if (block.timestamp - updatedAt > s.noPoolAge) reason = T.Reason.Feed;
        } else {
            (ok, poolPrice) = pool(a, s);
            if (!ok) return (T.Reason.Pool, answer, updatedAt, poolPrice);
            uint256 usd = value(10 ** a.tokenDecimals, answer, a.tokenDecimals, a.feedDecimals);
            uint256 difference = usd > poolPrice ? usd - poolPrice : poolPrice - usd;
            if (difference > FullMath.mulDiv(usd, s.poolDeviation, 10_000)) reason = T.Reason.Pool;
        }
    }

    /// @dev OracleLibrary.consult arithmetic: wrapped cumulatives, tick rounded toward -infinity,
    /// harmonic mean liquidity. Only the canonical two-observation ABI is accepted.
    function pool(T.Asset memory a, T.Settings memory s) internal view returns (bool ok, uint256 usd) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = uint32(s.poolWindow);
        bytes memory out;
        (ok, out) = read(a.pool, abi.encodeWithSignature("observe(uint32[])", secondsAgos), s.poolGas, 256);
        if (!ok) return (false, 0);
        uint256 offset0;
        uint256 offset1;
        uint256 length0;
        uint256 length1;
        int256 t0;
        int256 t1;
        uint256 l0;
        uint256 l1;
        assembly ("memory-safe") {
            offset0 := mload(add(out, 32))
            offset1 := mload(add(out, 64))
            length0 := mload(add(out, 96))
            t0 := mload(add(out, 128))
            t1 := mload(add(out, 160))
            length1 := mload(add(out, 192))
            l0 := mload(add(out, 224))
            l1 := mload(add(out, 256))
        }
        if (
            offset0 != 64 || offset1 != 160 || length0 != 2 || length1 != 2 || int256(int56(t0)) != t0
                || int256(int56(t1)) != t1 || l0 > type(uint160).max || l1 > type(uint160).max
        ) return (false, 0);
        int56 dt;
        uint160 dl;
        unchecked {
            dt = int56(t1) - int56(t0);
            dl = uint160(l1) - uint160(l0);
        }
        if (dl == 0) return (false, 0);
        int256 mean = dt / int256(s.poolWindow);
        if (dt < 0 && dt % int256(s.poolWindow) != 0) --mean;
        if (mean < -887272 || mean > 887272) return (false, 0);
        uint256 liquidity = (s.poolWindow * type(uint160).max) / (uint256(dl) << 32);
        if (liquidity > type(uint128).max || liquidity < a.minLiquidity) return (false, 0);
        uint160 sqrt = TickMath.getSqrtRatioAtTick(int24(mean));
        uint256 rawQuote;
        // Normalize before the tick quote to retain fractional whole quote tokens,
        // even when the quote token has few decimals.
        uint256 base = 10 ** (18 + uint256(a.tokenDecimals) - a.quoteDecimals);
        if (sqrt <= type(uint128).max) {
            uint256 ratio = uint256(sqrt) * sqrt;
            rawQuote = a.tokenIs0 ? FullMath.mulDiv(ratio, base, 1 << 192) : FullMath.mulDiv(1 << 192, base, ratio);
        } else {
            uint256 ratio = FullMath.mulDiv(sqrt, sqrt, 1 << 64);
            rawQuote = a.tokenIs0 ? FullMath.mulDiv(ratio, base, 1 << 128) : FullMath.mulDiv(1 << 128, base, ratio);
        }
        uint256 quoteAnswer;
        (ok, quoteAnswer,) = feed(a.quoteFeed, s.feedGas, s.maxAge);
        if (!ok) return (false, 0);
        usd = FullMath.mulDiv(rawQuote, quoteAnswer, 10 ** a.quoteFeedDecimals);
    }
}
