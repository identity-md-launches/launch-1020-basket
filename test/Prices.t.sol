// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {VaultFixture} from "./BaskVault.t.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {BaskTypes as T} from "../src/BaskTypes.sol";
import {BaskOracle as O} from "../src/libraries/BaskOracle.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockToken, MockFeed, MockPool, NoPauseToken} from "./Mocks.sol";

contract PriceTest is VaultFixture {
    MockToken private quote;
    MockFeed private quoteFeed;
    MockPool private pool;

    function _attachPool(uint128 minLiquidity) private {
        quote = new MockToken(18);
        quoteFeed = new MockFeed(8, 100e8);
        pool = new MockPool(address(tokens[0]), address(quote));
        _execute(
            _propose(T.Action.Pool, address(tokens[0]), abi.encode(address(pool), address(quoteFeed), minLiquidity))
        );
        quoteFeed.set(100e8, block.timestamp);
    }

    function testPriceAgeFutureSignAndReadFailures() public {
        feeds[0].set(100e8, block.timestamp - 26 hours);
        _status(T.Reason.OK, address(0));
        feeds[0].set(100e8, block.timestamp - 26 hours - 1);
        _status(T.Reason.Feed, address(tokens[0]));
        feeds[0].set(100e8, block.timestamp + 1);
        _status(T.Reason.Feed, address(tokens[0]));
        feeds[0].set(0, block.timestamp);
        _status(T.Reason.Feed, address(tokens[0]));
        feeds[0].set(-1, block.timestamp);
        _status(T.Reason.Feed, address(tokens[0]));
        for (uint256 mode = 1; mode <= 3; ++mode) {
            feeds[0].setMode(mode);
            _status(T.Reason.Feed, address(tokens[0]));
        }
    }

    function testBandBoundariesAndOraclePause() public {
        feeds[0].set(25e8, block.timestamp);
        _status(T.Reason.OK, address(0));
        feeds[0].set(25e8 - 1, block.timestamp);
        _status(T.Reason.Band, address(tokens[0]));
        feeds[0].set(400e8, block.timestamp);
        _status(T.Reason.OK, address(0));
        feeds[0].set(400e8 + 1, block.timestamp);
        _status(T.Reason.Band, address(tokens[0]));
        feeds[0].set(100e8, block.timestamp);
        tokens[0].setOraclePaused(true);
        _status(T.Reason.OraclePaused, address(tokens[0]));
        vm.mockCall(address(tokens[0]), abi.encodeWithSignature("oraclePaused()"), abi.encode(uint256(2)));
        _status(T.Reason.OraclePaused, address(tokens[0]));
    }

    function testEveryManagedAssetCheckedEvenClosedAndNotDeposited() public {
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(1e18), alice, 0, block.timestamp);
        vm.prank(owner);
        vault.close(address(tokens[1]));
        feeds[1].setMode(1);
        _status(T.Reason.Feed, address(tokens[1]));
        feeds[1].setMode(0);
        tokens[1].burn(address(vault), 1);
        _status(T.Reason.Deficit, address(tokens[1]));
    }

    function testFreshCountIncludesIdleClosedUnretiredAssets() public {
        _setting(T.Setting.FreshCount, 3);
        feeds[2].set(100e8, block.timestamp - 4 hours - 1);
        _status(T.Reason.Freshness, address(0));
        feeds[2].set(100e8, block.timestamp - 4 hours);
        vm.prank(owner);
        vault.close(address(tokens[2]));
        _status(T.Reason.OK, address(0));
        _execute(_propose(T.Action.Retire, address(tokens[2]), ""));
        _status(T.Reason.Freshness, address(0));
    }

    function testHoursWeekdayEndpointsAndAlwaysOpen() public {
        _setting(T.Setting.Hours, (uint256(9 hours) << 32) | uint256(17 hours));
        uint256 monday = (block.timestamp / 1 days + 7) / 7 * 7 * 1 days + 4 days;
        // Unix epoch Thursday; day 4 modulo 7 is Monday.
        vm.warp(monday + 9 hours);
        _refresh();
        _status(T.Reason.OK, address(0));
        vm.warp(monday + 17 hours);
        _refresh();
        _status(T.Reason.Hours, address(0));
        vm.warp(monday + 5 days + 10 hours);
        _refresh();
        _status(T.Reason.Hours, address(0));
        _setting(T.Setting.Hours, 0);
        _status(T.Reason.OK, address(0));
    }

    function testPoolTickZeroPriceLiquidityAndMaxAge() public {
        _attachPool(1e10);
        _status(T.Reason.OK, address(0));
        T.AssetView[] memory a = vault.allAssets();
        assertEq(a[0].poolPrice, 100e18);
        assertEq(a[0].answer, 100e8);
        assertEq(a[0].managed, 0);
        feeds[0].set(100e8, block.timestamp - 80 hours);
        _status(T.Reason.OK, address(0));
        feeds[0].set(100e8, block.timestamp - 80 hours - 1);
        _status(T.Reason.Feed, address(tokens[0]));
        feeds[0].set(100e8, block.timestamp);
        pool.set(0, uint160((uint256(1800) << 128) / 1e8));
        _status(T.Reason.Pool, address(tokens[0]));
    }

    function testPoolDeviationQuoteStaleAndObserveFailures() public {
        _attachPool(0);
        quoteFeed.set(103e8, block.timestamp);
        _status(T.Reason.OK, address(0));
        quoteFeed.set(103e8 + 1, block.timestamp);
        _status(T.Reason.Pool, address(tokens[0]));
        quoteFeed.set(97e8, block.timestamp);
        _status(T.Reason.OK, address(0));
        quoteFeed.set(97e8 - 1, block.timestamp);
        _status(T.Reason.Pool, address(tokens[0]));
        quoteFeed.set(100e8, block.timestamp - 80 hours - 1);
        _status(T.Reason.Pool, address(tokens[0]));
        quoteFeed.set(100e8, block.timestamp);
        for (uint256 mode = 1; mode <= 3; ++mode) {
            pool.setMode(mode);
            _status(T.Reason.Pool, address(tokens[0]));
        }
    }

    function testNegativeFractionalMeanRoundsDownAndCumulativesWrap() public {
        _attachPool(0);
        pool.set(-1, uint160((uint256(1800) << 128) / 1e12));
        pool.setStarts(type(int56).min, type(uint160).max - 100);
        _status(T.Reason.OK, address(0));
        uint256 sqrt = TickMath.getSqrtRatioAtTick(-1);
        uint256 ratio = sqrt * sqrt;
        bool is0 = address(tokens[0]) < address(quote);
        uint256 expected = is0 ? FullMath.mulDiv(ratio, 1e18, 1 << 192) : FullMath.mulDiv(1 << 192, 1e18, ratio);
        assertEq(vault.allAssets()[0].poolPrice, expected * 100);
        assertTrue(expected != 1e18);
    }

    function testRemovePoolReturnsToNoPoolAgeAndWrongPoolRejected() public {
        _attachPool(0);
        _execute(_propose(T.Action.Pool, address(tokens[0]), abi.encode(address(0), address(0), uint128(0))));
        feeds[0].set(100e8, block.timestamp - 27 hours);
        _status(T.Reason.Feed, address(tokens[0]));
        MockPool wrong = new MockPool(address(tokens[1]), address(quote));
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.propose(T.Action.Pool, address(tokens[0]), abi.encode(address(wrong), address(quoteFeed), uint128(0)));
    }

    function testMixedDecimalsAndExactValueRounding() public {
        vault = new BaskVault(owner, guardian);
        delete tokens;
        delete feeds;
        _add(6, 8, 123456789);
        _add(18, 18, 1e18);
        _add(0, 0, 5);
        vm.prank(owner);
        vault.finalizeGenesis();
        uint256 shares = _deposit(1_234_567);
        uint256 value = uint256(1_234_567) * 123456789 * 1e4;
        assertEq(shares, value - 1e15);
        vm.prank(alice);
        uint256 more = vault.deposit(_one(address(tokens[2])), _amount(1), alice, 0, block.timestamp);
        assertEq(more, 5e18);
    }

    function testFractionalQuoteWithZeroDecimalsIsNotRoundedToWholeQuote() public {
        vault = new BaskVault(owner, guardian);
        delete tokens;
        delete feeds;
        _add(0, 8, 150e8);
        _add(18, 8, 100e8);
        _add(18, 8, 100e8);
        MockToken q = new MockToken(0);
        MockFeed qf = new MockFeed(8, 100e8);
        MockPool p = new MockPool(address(tokens[0]), address(q));
        int56 tick = address(tokens[0]) < address(q) ? int56(4055) : int56(-4055);
        p.set(tick * 1800, uint160((uint256(1800) << 128) / 1e12));
        _execute(_propose(T.Action.Pool, address(tokens[0]), abi.encode(address(p), address(qf), uint128(0))));
        qf.set(100e8, block.timestamp);
        vm.prank(owner);
        vault.finalizeGenesis();
        _status(T.Reason.OK, address(0));
        uint256 price = vault.allAssets()[0].poolPrice;
        assertApproxEqAbs(price, 150e18, 0.02e18);
    }

    function testOptionalPauseAbsentAtListing() public {
        NoPauseToken t = new NoPauseToken();
        MockFeed f = new MockFeed(8, 1e8);
        uint256 id = _propose(T.Action.List, address(t), abi.encode(address(f), address(0), address(0), uint128(0)));
        _execute(id);
        f.set(1e8, block.timestamp);
        assertFalse(vault.asset(address(t)).hasPause);
        t.mint(alice, 1e18);
        vm.prank(alice);
        assertGt(vault.deposit(_one(address(t)), _amount(1e18), alice, 0, block.timestamp), 0);
    }
}
