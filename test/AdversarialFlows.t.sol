// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {VaultFixture} from "./BaskVault.t.sol";
import {BaskVault} from "src/BaskVault.sol";
import {BaskTypes as T} from "src/BaskTypes.sol";
import {MockToken, MockFeed} from "./Mocks.sol";

contract AdversarialFlowsTest is VaultFixture {
    function _basket(uint256 count, uint256 amount)
        private
        view
        returns (address[] memory ts, uint256[] memory amounts)
    {
        ts = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ts[i] = address(tokens[i]);
            amounts[i] = amount;
        }
    }

    function test_SecondPullFailureRevertsFirstPullAllowanceAndMint() public {
        (address[] memory ts, uint256[] memory amounts) = _basket(2, 1e18);
        uint256 firstBalance = tokens[0].balanceOf(alice);
        vm.prank(alice);
        tokens[0].approve(address(vault), 1e18);
        tokens[1].setModes(0, 3); // It moves tokens, then returns false.
        vm.prank(alice);
        vm.expectRevert(BaskVault.TransferFailed.selector);
        vault.deposit(ts, amounts, bob, 0, block.timestamp);
        assertEq(tokens[0].balanceOf(alice), firstBalance);
        assertEq(tokens[0].allowance(alice, address(vault)), 1e18);
        for (uint256 i; i < 2; ++i) {
            assertEq(tokens[i].balanceOf(address(vault)), 0);
            assertEq(vault.managed(ts[i]), 0);
        }
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(address(0xdEaD)), 0);
    }

    function test_LateRedeemMinimumRevertsEarlierPaymentDebtFeeAndBurn() public {
        _execute(_propose(T.Action.FeeRecipient, address(0), abi.encode(recipient)));
        (address[] memory ts, uint256[] memory amounts) = _basket(3, 10e18);
        vm.prank(alice);
        uint256 shares = vault.deposit(ts, amounts, alice, 0, block.timestamp);
        uint256 supply = vault.totalSupply();
        uint256 fees = vault.balanceOf(recipient);
        tokens[1].setPaused(true); // First leg pays, second leg defers, third leg fails slippage.
        uint256[] memory minima = new uint256[](3);
        minima[2] = 11e18;
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(shares, bob, minima, block.timestamp);
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(recipient), fees);
        for (uint256 i; i < 3; ++i) {
            assertEq(tokens[i].balanceOf(address(vault)), 10e18);
            assertEq(tokens[i].balanceOf(bob), 0);
            assertEq(vault.managed(ts[i]), 10e18);
            assertEq(vault.owed(bob, ts[i]), 0);
            assertEq(vault.totalOwed(ts[i]), 0);
        }
    }

    function test_ClaimsBelongToReceiverAndCannotBeStolenOrPaidTwice() public {
        _setting(T.Setting.DirectLimit, 0);
        uint256 shares = _deposit(10e18);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(shares / 2, bob, new uint256[](0), block.timestamp);
        address token = address(tokens[0]);
        assertEq(vault.owed(alice, token), 0);
        vm.prank(alice);
        vault.claim(_one(token), alice);
        assertEq(vault.owed(bob, token), legs[0]);
        (address[] memory duplicates,) = _basket(2, 0);
        duplicates[1] = token;
        vm.prank(bob);
        vault.claim(duplicates, recipient);
        vm.prank(bob);
        vault.claim(duplicates, recipient);
        assertEq(tokens[0].balanceOf(recipient), legs[0]);
        assertEq(vault.totalOwed(token), 0);
        assertEq(vault.owed(bob, token), 0);
        assertEq(tokens[0].balanceOf(address(vault)), vault.managed(token));
    }

    function test_FailedClaimRollsBackTokenSideEffectsAndContinuesNextAsset() public {
        _setting(T.Setting.DirectLimit, 0);
        (address[] memory ts, uint256[] memory amounts) = _basket(2, 10e18);
        vm.prank(alice);
        uint256 shares = vault.deposit(ts, amounts, alice, 0, block.timestamp);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(shares / 2, bob, new uint256[](0), block.timestamp);
        tokens[0].setModes(0, 3);
        vm.prank(bob);
        vault.claim(ts, recipient);
        assertEq(tokens[0].balanceOf(recipient), 0);
        assertEq(tokens[0].balanceOf(address(vault)), 10e18);
        assertEq(vault.owed(bob, ts[0]), legs[0]);
        assertEq(vault.totalOwed(ts[0]), legs[0]);
        assertEq(tokens[1].balanceOf(recipient), legs[1]);
        assertEq(vault.owed(bob, ts[1]), 0);
        tokens[0].setModes(0, 4); // Successful recovery with no return value.
        vm.prank(bob);
        vault.claim(ts, recipient);
        assertEq(tokens[0].balanceOf(recipient), legs[0]);
        assertEq(tokens[1].balanceOf(recipient), legs[1]);
        assertEq(vault.totalOwed(ts[0]), 0);
    }

    function test_ExternalTokenCodeDisappearsAndClaimsSurviveRestoration() public {
        uint256 shares = _deposit(10e18);
        address token = address(tokens[0]);
        bytes memory originalCode = token.code;
        vm.etch(token, hex"");
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(shares, bob, new uint256[](0), block.timestamp);
        assertGt(legs[0], 0);
        assertEq(vault.owed(bob, token), legs[0]);
        vm.prank(bob);
        vault.claim(_one(token), bob);
        assertEq(vault.owed(bob, token), legs[0]);
        vm.etch(token, originalCode);
        vm.prank(bob);
        vault.claim(_one(token), bob);
        assertEq(tokens[0].balanceOf(bob), legs[0]);
        assertEq(vault.totalOwed(token), 0);
        assertEq(tokens[0].balanceOf(address(vault)), vault.managed(token));
    }

    function test_ResyncAddsOnlySurplusAfterClaimsAndDoesNotRecognizeLoss() public {
        _setting(T.Setting.DirectLimit, 0);
        uint256 shares = _deposit(10e18);
        _redeem(shares / 2);
        address token = address(tokens[0]);
        uint256 m = vault.managed(token);
        uint256 debt = vault.totalOwed(token);
        uint256 supply = vault.totalSupply();
        tokens[0].mint(address(vault), 3e18);
        _execute(_propose(T.Action.Resync, token, ""));
        assertEq(vault.managed(token), m + 3e18);
        assertEq(vault.totalOwed(token), debt);
        assertEq(vault.totalSupply(), supply);
        tokens[0].burn(address(vault), 4e18);
        _execute(_propose(T.Action.Resync, token, ""));
        assertEq(vault.managed(token), m + 3e18, "negative surplus cannot silently write off managed assets");
        _status(T.Reason.Deficit, token);
    }

    function test_DirectLimitCountsManagedAssetsIncludingRetiredOnes() public {
        _setting(T.Setting.DirectLimit, 1);
        uint256 shares = _deposit(10e18);
        uint256[] memory direct = _redeem(shares / 4);
        assertGt(direct[0], 0);
        assertEq(vault.totalOwed(address(tokens[0])), 0, "idle listings do not force deferral");
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(10e18), alice, 0, block.timestamp);
        vm.prank(guardian);
        vault.close(address(tokens[0]));
        _execute(_propose(T.Action.Retire, address(tokens[0]), ""));
        uint256[] memory deferred = _redeem(shares / 4);
        assertGt(deferred[0], 0);
        assertGt(deferred[1], 0);
        assertEq(vault.totalOwed(address(tokens[0])), deferred[0]);
        assertEq(vault.totalOwed(address(tokens[1])), deferred[1]);
    }

    function test_ZeroNavRejectsDepositButRetiredStockTokensRemainRedeemable() public {
        uint256 shares = _deposit(10e18);
        vm.prank(guardian);
        vault.close(address(tokens[0]));
        _execute(_propose(T.Action.Retire, address(tokens[0]), ""));
        vm.prank(alice);
        vm.expectRevert(BaskVault.ZeroNAV.selector);
        vault.deposit(_one(address(tokens[1])), _amount(1e18), alice, 0, block.timestamp);
        feeds[0].setMode(2);
        assertGt(_redeem(shares)[0], 0);
    }

    function test_EmptyMismatchedAndZeroInputsRejectWithoutCustodyChanges() public {
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.deposit(new address[](0), new uint256[](0), alice, 0, block.timestamp);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.deposit(_one(address(tokens[0])), new uint256[](0), alice, 0, block.timestamp);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.deposit(_one(address(tokens[0])), _amount(1e18), address(0), 0, block.timestamp);
        vm.expectRevert(BaskVault.InsufficientBalance.selector);
        vault.redeem(0, alice, new uint256[](0), block.timestamp);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.claim(new address[](0), address(0));
        vault.claim(new address[](0), alice);
        assertEq(vault.totalSupply(), 0);
        assertEq(tokens[0].balanceOf(address(vault)), 0);
    }

    function test_RedeemExpiredZeroReceiverAndOverspendLeaveSharesUntouched() public {
        uint256 shares = _deposit(1e18);
        vm.startPrank(alice);
        vm.expectRevert(BaskVault.Expired.selector);
        vault.redeem(shares, bob, new uint256[](0), block.timestamp - 1);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.redeem(shares, address(0), new uint256[](0), block.timestamp);
        vm.expectRevert(BaskVault.InsufficientBalance.selector);
        vault.redeem(shares + 1, bob, new uint256[](0), block.timestamp);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.managed(address(tokens[0])), 1e18);
    }

    function test_MinimumInitialSharesExactBoundaryAndNextTokenUnit() public {
        vm.expectRevert(BaskVault.Slippage.selector);
        _deposit(1e13); // Exactly 1e15 shares, all of which would be locked.
        assertEq(_deposit(1e13 + 1), 100);
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.totalSupply(), 1e15 + 100);
    }

    function test_FeeRecipientCanRedeemOwnBalanceAndOneWeiFeeDoesNotUnderflow() public {
        _execute(_propose(T.Action.FeeRecipient, address(0), abi.encode(alice)));
        _deposit(10e18);
        uint256 before = vault.balanceOf(alice);
        uint256 supply = vault.totalSupply();
        uint256[] memory dust = _redeem(1);
        assertEq(dust[0], 0); // ceil(1 * 50 / 10000) = 1, net burn is zero.
        assertEq(vault.balanceOf(alice), before);
        assertEq(vault.totalSupply(), supply);
        uint256[] memory legs = _redeem(before);
        uint256 fee = (before * 50 + 9999) / 10000;
        assertEq(vault.balanceOf(alice), fee);
        assertEq(vault.totalSupply(), supply - before + fee);
        assertEq(legs[0], 10e18 * (before - fee) / supply);
    }

    function test_ShareAllowanceFailureRollsBackAndUnlimitedAllowancePersists() public {
        uint256 shares = _deposit(1e18);
        vm.prank(alice);
        vault.approve(bob, shares + 1);
        vm.prank(bob);
        vm.expectRevert(BaskVault.InsufficientBalance.selector);
        vault.transferFrom(alice, bob, shares + 1);
        assertEq(vault.allowance(alice, bob), shares + 1);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.prank(bob);
        vault.transferFrom(alice, alice, shares);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
        assertEq(vault.balanceOf(alice), shares);
        vm.prank(bob);
        vault.transferFrom(alice, bob, shares);
        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RepeatedDepositRedeemCyclesCannotCreateProfit(
        uint128 raw,
        uint64 donationRaw,
        uint8 roundsRaw,
        bool withFee,
        bool deferred
    ) public {
        _deposit(10e18);
        uint256 donation = bound(donationRaw, 0, 100e18);
        tokens[0].mint(address(vault), donation);
        _execute(_propose(T.Action.Resync, address(tokens[0]), ""));
        if (withFee) _execute(_propose(T.Action.FeeRecipient, address(0), abi.encode(recipient)));
        if (deferred) _setting(T.Setting.DirectLimit, 0);
        uint256 amount = bound(raw, 1e14, 1000e18);
        uint256 rounds = bound(roundsRaw, 1, 8);
        tokens[0].mint(bob, amount);
        vm.prank(bob);
        tokens[0].approve(address(vault), type(uint256).max);
        uint256 start = tokens[0].balanceOf(bob);
        for (uint256 i; i < rounds; ++i) {
            uint256 before = tokens[0].balanceOf(bob);
            vm.startPrank(bob);
            uint256 shares = vault.deposit(_one(address(tokens[0])), _amount(before), bob, 0, block.timestamp);
            vault.redeem(shares, bob, new uint256[](0), block.timestamp);
            vault.claim(_one(address(tokens[0])), bob);
            vm.stopPrank();
            assertLe(tokens[0].balanceOf(bob), before, "a cycle cannot create Stock Tokens");
            assertEq(vault.balanceOf(bob), 0);
            assertEq(vault.owed(bob, address(tokens[0])), 0);
        }
        assertLe(tokens[0].balanceOf(bob), start);
        assertEq(tokens[0].balanceOf(address(vault)), vault.managed(address(tokens[0])));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FirstDepositValueAcrossSupportedDecimals(uint8 tokenRaw, uint8 feedRaw, uint96 raw) public {
        uint8 td = uint8(bound(tokenRaw, 0, 18));
        uint8 fd = uint8(bound(feedRaw, 0, 18));
        BaskVault v = new BaskVault(owner, guardian);
        MockToken t;
        for (uint256 i; i < 3; ++i) {
            MockToken next = new MockToken(td);
            MockFeed f = new MockFeed(fd, int256(7 * 10 ** fd));
            vm.prank(owner);
            v.genesisList(address(next), address(f), address(0), address(0), 0);
            if (i == 0) t = next;
        }
        vm.prank(owner);
        v.finalizeGenesis();
        uint256 amount = bound(raw, 10 ** td, 100 * 10 ** td);
        t.mint(alice, amount);
        vm.startPrank(alice);
        t.approve(address(v), amount);
        uint256 shares = v.deposit(_one(address(t)), _amount(amount), bob, 0, block.timestamp);
        vm.stopPrank();
        // Safe full-width reference expression from the specification; no production math helper.
        uint256 dollars = amount * (7 * 10 ** fd) * 1e18 / (10 ** (uint256(td) + fd));
        assertEq(shares + 1e15, dollars);
        assertEq(v.balanceOf(bob), shares);
        assertEq(v.balanceOf(alice), 0);
        assertEq(v.totalSupply(), dollars);
        assertEq(v.managed(address(t)), amount);
    }
}
