// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {VaultFixture} from "./BaskVault.t.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {BaskTypes as T} from "../src/BaskTypes.sol";
import {MockToken, MockFeed} from "./Mocks.sol";

contract HeldAccountingTest is VaultFixture {
    function _depositToken(uint256 i, uint256 amount) private {
        vm.prank(alice);
        vault.deposit(_one(address(tokens[i])), _amount(amount), alice, 0, block.timestamp);
    }

    function _redeemToBob() private returns (uint256[] memory legs) {
        uint256 shares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        return vault.redeem(shares, bob, new uint256[](0), block.timestamp);
    }

    function _recognize(uint256 i) private {
        vault.flagDeficit(address(tokens[i]));
        vm.warp(block.timestamp + 7 days);
        vault.recognizeLoss(address(tokens[i]));
    }

    function testRepeatedDepositsCountOneHoldingAndNewAssetDefersPayments() public {
        _setting(T.Setting.DirectLimit, 1);
        _deposit(10e18);
        _deposit(10e18);
        uint256[] memory direct = _redeemToBob();
        assertGt(direct[0], 0);
        assertEq(tokens[0].balanceOf(bob), direct[0]);
        assertEq(vault.owed(bob, address(tokens[0])), 0);

        _depositToken(1, 10e18);
        uint256 beforeBalance = tokens[0].balanceOf(bob);
        uint256[] memory deferred = _redeemToBob();
        assertGt(deferred[0], 0);
        assertGt(deferred[1], 0);
        assertEq(tokens[0].balanceOf(bob), beforeBalance);
        assertEq(tokens[1].balanceOf(bob), 0);
        assertEq(vault.owed(bob, address(tokens[0])), deferred[0]);
        assertEq(vault.owed(bob, address(tokens[1])), deferred[1]);
    }

    function testResyncActivatesOnlyNewPositiveHoldings() public {
        _setting(T.Setting.DirectLimit, 1);
        _deposit(10e18);
        _execute(_propose(T.Action.Resync, address(tokens[2]), ""));
        tokens[0].mint(address(vault), 10e18);
        _execute(_propose(T.Action.Resync, address(tokens[0]), ""));
        uint256[] memory direct = _redeemToBob();
        assertEq(tokens[0].balanceOf(bob), direct[0]);
        assertGt(direct[0], 0);
        assertEq(vault.owed(bob, address(tokens[0])), 0);

        tokens[1].mint(address(vault), 10e18);
        _execute(_propose(T.Action.Resync, address(tokens[1]), ""));
        uint256 beforeBalance = tokens[0].balanceOf(bob);
        uint256[] memory deferred = _redeemToBob();
        assertEq(tokens[0].balanceOf(bob), beforeBalance);
        assertEq(tokens[1].balanceOf(bob), 0);
        assertEq(vault.owed(bob, address(tokens[0])), deferred[0]);
        assertEq(vault.owed(bob, address(tokens[1])), deferred[1]);
        assertGt(deferred[1], 0);
        assertEq(deferred[2], 0);
    }

    function testPartialLossKeepsHoldingAndFullLossRestoresDirectPayments() public {
        _setting(T.Setting.DirectLimit, 1);
        _deposit(10e18);
        _depositToken(1, 10e18);
        tokens[1].burn(address(vault), 5e18);
        _recognize(1);
        assertEq(vault.managed(address(tokens[1])), 5e18);
        uint256[] memory deferred = _redeemToBob();
        assertEq(tokens[0].balanceOf(bob), 0);
        assertEq(tokens[1].balanceOf(bob), 0);
        assertEq(vault.owed(bob, address(tokens[0])), deferred[0]);
        assertEq(vault.owed(bob, address(tokens[1])), deferred[1]);
        assertGt(deferred[1], 0);

        tokens[1].burn(address(vault), tokens[1].balanceOf(address(vault)));
        _recognize(1);
        assertEq(vault.managed(address(tokens[1])), 0);
        uint256[] memory direct = _redeemToBob();
        assertGt(direct[0], 0);
        assertEq(tokens[0].balanceOf(bob), direct[0]);
        assertEq(vault.owed(bob, address(tokens[0])), deferred[0]);
        assertEq(vault.owed(bob, address(tokens[1])), deferred[1]);
        assertEq(direct[1], 0);

        // A later deposit into the fully written-down asset must activate it again.
        tokens[1].mint(address(vault), deferred[1]);
        _refresh();
        _depositToken(1, 10e18);
        uint256 beforeBalance = tokens[0].balanceOf(bob);
        uint256[] memory reactivated = _redeemToBob();
        assertEq(tokens[0].balanceOf(bob), beforeBalance);
        assertEq(vault.owed(bob, address(tokens[0])), deferred[0] + reactivated[0]);
        assertEq(vault.owed(bob, address(tokens[1])), deferred[1] + reactivated[1]);
        assertGt(reactivated[1], 0);
    }

    function testRetiredHoldingsRemainInDirectLimitAndRedemption() public {
        _setting(T.Setting.DirectLimit, 1);
        _deposit(10e18);
        _depositToken(1, 10e18);
        vm.prank(owner);
        vault.close(address(tokens[1]));
        _execute(_propose(T.Action.Retire, address(tokens[1]), ""));
        uint256[] memory legs = _redeemToBob();
        assertGt(legs[0], 0);
        assertGt(legs[1], 0);
        assertEq(tokens[0].balanceOf(bob), 0);
        assertEq(tokens[1].balanceOf(bob), 0);
        assertEq(vault.owed(bob, address(tokens[0])), legs[0]);
        assertEq(vault.owed(bob, address(tokens[1])), legs[1]);
    }

    function testMinimumForIdleAssetRevertsAndRollsBackOtherLegs() public {
        _deposit(10e18);
        uint256[] memory minimums = new uint256[](3);
        minimums[2] = 1;
        uint256 shares = vault.balanceOf(alice);
        uint256 supply = vault.totalSupply();
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(shares / 2, bob, minimums, block.timestamp);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.managed(address(tokens[0])), 10e18);
        assertEq(tokens[0].balanceOf(bob), 0);
        assertEq(vault.owed(bob, address(tokens[0])), 0);
    }

    function testRemovingIdleSlotMovesHeldLastAssetWithinBitmapWord() public {
        _depositToken(2, 10e18);
        vm.prank(owner);
        vault.close(address(tokens[0]));
        _execute(_propose(T.Action.Retire, address(tokens[0]), ""));
        vault.removeRetired(address(tokens[0]));
        assertEq(vault.assetTokens(0), address(tokens[2]));
        uint256[] memory legs = _redeemToBob();
        assertEq(legs.length, 2);
        assertGt(legs[0], 0);
        assertEq(tokens[2].balanceOf(bob), legs[0]);
        assertEq(legs[1], 0);
    }
}

contract HeldAccountingBoundaryTest is VaultFixture {
    function setUp() public override {
        vm.warp(1_800_000_000);
        vault = new BaskVault(owner, guardian);
        _setting(T.Setting.BalanceGas, 20_000);
        _setting(T.Setting.MaxAssets, 257);
        _setting(T.Setting.DirectLimit, 1);
        bytes memory tokenCode = address(new MockToken(18)).code;
        bytes memory feedCode = address(new MockFeed(0, 100)).code;
        for (uint256 i; i < 257; ++i) {
            // Distinct test contracts with normal storage writes through their mock API.
            MockToken token = MockToken(address(uint160(0x300000 + i)));
            MockFeed feed = MockFeed(address(uint160(0x400000 + i)));
            vm.etch(address(token), tokenCode);
            vm.etch(address(feed), feedCode);
            feed.set(100, block.timestamp);
            tokens.push(token);
            feeds.push(feed);
            vm.prank(owner);
            vault.genesisList(address(token), address(feed), address(0), address(0), 0);
        }
        vm.prank(owner);
        vault.finalizeGenesis();
    }

    function _depositToken(uint256 i) private {
        tokens[i].mint(alice, 10e18);
        vm.prank(alice);
        tokens[i].approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(_one(address(tokens[i])), _amount(10e18), alice, 0, block.timestamp);
    }

    function _redeemToBob() private returns (uint256[] memory legs) {
        uint256 shares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        return vault.redeem(shares, bob, new uint256[](0), block.timestamp);
    }

    function testMoveAcrossBitmapWordsRelistOldSlotAndClearMovedHolding() public {
        _depositToken(256);
        vm.prank(owner);
        vault.close(address(tokens[255]));
        _execute(_propose(T.Action.Retire, address(tokens[255]), ""));
        vault.removeRetired(address(tokens[255]));
        assertEq(vault.assetCount(), 256);
        assertEq(vault.assetTokens(255), address(tokens[256]));
        uint256[] memory moved = _redeemToBob();
        assertEq(moved.length, 256);
        assertGt(moved[255], 0);
        assertEq(tokens[256].balanceOf(bob), moved[255]);
        assertEq(vault.owed(bob, address(tokens[256])), 0);

        _execute(
            _propose(
                T.Action.List, address(tokens[255]), abi.encode(address(feeds[255]), address(0), address(0), uint128(0))
            )
        );
        assertEq(vault.assetTokens(256), address(tokens[255]));
        _depositToken(255);
        uint256 beforeBalance = tokens[256].balanceOf(bob);
        uint256[] memory both = _redeemToBob();
        assertEq(both.length, 257);
        assertGt(both[255], 0);
        assertGt(both[256], 0);
        assertEq(tokens[256].balanceOf(bob), beforeBalance);
        assertEq(tokens[255].balanceOf(bob), 0);
        assertEq(vault.owed(bob, address(tokens[256])), both[255]);
        assertEq(vault.owed(bob, address(tokens[255])), both[256]);

        tokens[256].burn(address(vault), tokens[256].balanceOf(address(vault)));
        vault.flagDeficit(address(tokens[256]));
        vm.warp(block.timestamp + 7 days);
        vault.recognizeLoss(address(tokens[256]));
        assertEq(vault.managed(address(tokens[256])), 0);
        uint256[] memory remaining = _redeemToBob();
        assertEq(remaining[255], 0);
        assertGt(remaining[256], 0);
        assertEq(tokens[255].balanceOf(bob), remaining[256]);
        assertEq(vault.owed(bob, address(tokens[255])), both[256]);
    }
}
