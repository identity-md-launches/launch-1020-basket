// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {VaultFixture} from "./BaskVault.t.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {BaskTypes as T} from "../src/BaskTypes.sol";
import {BaskOracle as O} from "../src/libraries/BaskOracle.sol";
import {MockToken, MockFeed} from "./Mocks.sol";

contract GovernanceTest is VaultFixture {
    function testGenesisThresholdAndFinalizationOnce() public {
        vault = new BaskVault(owner, guardian);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.finalizeGenesis();
        for (uint256 i; i < 3; ++i) {
            vm.prank(owner);
            vault.genesisList(address(tokens[i]), address(feeds[i]), address(0), address(0), 0);
        }
        _status(T.Reason.Genesis, address(0));
        vm.prank(owner);
        vault.finalizeGenesis();
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.finalizeGenesis();
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.genesisList(address(tokens[0]), address(feeds[0]), address(0), address(0), 0);
    }

    function testOnlyOwnerExecutionTimelockAndExpiry() public {
        uint256 id = _propose(T.Action.FeeRecipient, address(0), abi.encode(recipient));
        vm.prank(owner);
        vm.expectRevert(BaskVault.TooEarly.selector);
        vault.execute(id);
        vm.warp(vault.proposal(id).readyAt);
        vm.prank(guardian);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.execute(id);
        vm.prank(owner);
        vault.execute(id);
        assertEq(vault.feeRecipient(), recipient);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.execute(id);
        id = _propose(T.Action.FeeRecipient, address(0), abi.encode(bob));
        vm.warp(vault.proposal(id).readyAt + 7 days + 1);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.execute(id);
    }

    function testExecutionAtLastSecondAndPendingEnumeration() public {
        uint256 id = _propose(T.Action.FeeRecipient, address(0), abi.encode(recipient));
        (uint256[] memory ids, T.Proposal[] memory p) = vault.pendingProposals(0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        assertEq(p[0].data, abi.encode(recipient));
        vm.warp(p[0].readyAt + 7 days);
        vm.prank(owner);
        vault.execute(id);
        (ids,) = vault.pendingProposals(0, 10);
        assertEq(ids.length, 0);
    }

    function testGuardianCannotCancelReplacementButOwnerCan() public {
        uint256 id = _propose(T.Action.Guardian, address(0), abi.encode(bob));
        vm.prank(guardian);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.cancel(id);
        vm.prank(owner);
        vault.cancel(id);
        assertFalse(vault.proposalValid(id));
        id = _propose(T.Action.FeeRecipient, address(0), abi.encode(recipient));
        vm.prank(guardian);
        vault.cancel(id);
        assertFalse(vault.proposalValid(id));
        _execute(_propose(T.Action.Guardian, address(0), abi.encode(bob)));
        vm.prank(guardian);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.pauseDeposits();
        vm.prank(bob);
        vault.pauseDeposits();
    }

    function testTwoStepOwnerNeverGuardianEvenAcrossRoleChanges() public {
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(guardian);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(address(0));
        vm.prank(owner);
        vault.transferOwnership(bob);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.acceptOwnership();
        _execute(_propose(T.Action.Guardian, address(0), abi.encode(bob)));
        vm.prank(bob);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.acceptOwnership();
        vm.prank(owner);
        vault.transferOwnership(alice);
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
        vm.prank(owner);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.unpauseDeposits();
    }

    function testGuardianProposalRechecksNewOwnerAtExecution() public {
        uint256 id = _propose(T.Action.Guardian, address(0), abi.encode(bob));
        vm.prank(owner);
        vault.transferOwnership(bob);
        vm.prank(bob);
        vault.acceptOwnership();
        vm.warp(vault.proposal(id).readyAt);
        vm.prank(bob);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.execute(id);
    }

    function testCloseCancelsAllOlderReopenProposals() public {
        vm.prank(owner);
        vault.close(address(tokens[0]));
        uint256 first = _propose(T.Action.Reopen, address(tokens[0]), "");
        uint256 second = _propose(T.Action.Reopen, address(tokens[0]), "");
        vm.prank(guardian);
        vault.close(address(tokens[0]));
        assertFalse(vault.proposalValid(first));
        assertFalse(vault.proposalValid(second));
        _execute(_propose(T.Action.Reopen, address(tokens[0]), ""));
        assertTrue(vault.asset(address(tokens[0])).open);
    }

    function testRetireClosedAtBothTimesInvalidatesPendingForever() public {
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.propose(T.Action.Retire, address(tokens[0]), "");
        vm.prank(owner);
        vault.close(address(tokens[0]));
        uint256 retireId = _propose(T.Action.Retire, address(tokens[0]), "");
        uint256 reopenId = _propose(T.Action.Reopen, address(tokens[0]), "");
        _execute(reopenId);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.execute(retireId);
        vm.prank(owner);
        vault.close(address(tokens[0]));
        uint256 centreId = _propose(T.Action.Centre, address(tokens[0]), "");
        uint256 resyncId = _propose(T.Action.Resync, address(tokens[0]), "");
        vm.prank(owner);
        vault.execute(retireId);
        assertFalse(vault.proposalValid(centreId));
        assertFalse(vault.proposalValid(resyncId));
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.propose(T.Action.Reopen, address(tokens[0]), "");
        tokens[0].mint(address(vault), 1e18);
        _execute(_propose(T.Action.Resync, address(tokens[0]), ""));
        assertEq(vault.managed(address(tokens[0])), 1e18);
    }

    function testRetiredHoldingsIgnoredByDepositAndSharedWithLaterDepositor() public {
        _deposit(10e18);
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(10e18), alice, 0, block.timestamp);
        vm.prank(owner);
        vault.close(address(tokens[0]));
        _execute(_propose(T.Action.Retire, address(tokens[0]), ""));
        feeds[0].setMode(2);
        tokens[0].setModes(2, 2);
        vm.prank(alice);
        uint256 shares = vault.deposit(_one(address(tokens[1])), _amount(10e18), bob, 0, block.timestamp);
        assertEq(shares, 2000e18);
        vm.prank(bob);
        uint256[] memory legs = vault.redeem(shares, bob, new uint256[](0), block.timestamp);
        assertEq(legs[0], 5e18);
        assertEq(vault.owed(bob, address(tokens[0])), 5e18);
    }

    function testRemoveRetiredAndRelistAndReuseFeed() public {
        vm.prank(owner);
        vault.close(address(tokens[2]));
        _execute(_propose(T.Action.Retire, address(tokens[2]), ""));
        vm.prank(alice);
        vault.removeRetired(address(tokens[2]));
        assertEq(vault.assetCount(), 2);
        uint256 id = _propose(
            T.Action.List, address(tokens[2]), abi.encode(address(feeds[2]), address(0), address(0), uint128(0))
        );
        _execute(id);
        assertEq(vault.assetCount(), 3);
        assertTrue(vault.asset(address(tokens[2])).open);
        assertFalse(vault.asset(address(tokens[2])).retired);
    }

    function testListingAndNewFeedRecheckDecimalsUniquenessFreshness() public {
        MockToken extra = new MockToken(18);
        MockFeed f = new MockFeed(8, 10e8);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.propose(T.Action.List, address(extra), abi.encode(address(feeds[0]), address(0), address(0), uint128(0)));
        MockToken bad = new MockToken(19);
        vm.prank(owner);
        vm.expectRevert(O.InvalidOracle.selector);
        vault.propose(T.Action.List, address(bad), abi.encode(address(f), address(0), address(0), uint128(0)));
        uint256 id = _propose(T.Action.List, address(extra), abi.encode(address(f), address(0), address(0), uint128(0)));
        vm.warp(vault.proposal(id).readyAt + 2 days);
        vm.prank(owner);
        vm.expectRevert(O.InvalidOracle.selector);
        vault.execute(id);
        f.set(20e8, block.timestamp);
        vm.prank(owner);
        vault.execute(id);
        assertEq(vault.asset(address(extra)).centre, 20e8);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.propose(T.Action.Feed, address(tokens[0]), abi.encode(address(f)));
        MockFeed newFeed = new MockFeed(6, 50e6);
        id = _propose(T.Action.Feed, address(tokens[0]), abi.encode(address(newFeed)));
        _execute(id);
        assertEq(vault.asset(address(tokens[0])).centre, 50e6);
        assertEq(vault.asset(address(tokens[0])).feedDecimals, 6);
    }

    function testRecentreUsesExecutionAnswerAndRejectsStale() public {
        uint256 id = _propose(T.Action.Centre, address(tokens[0]), "");
        feeds[0].set(200e8, block.timestamp);
        _execute(id);
        assertEq(vault.asset(address(tokens[0])).centre, 200e8);
        vm.warp(block.timestamp + 4 days);
        id = _propose(T.Action.Centre, address(tokens[0]), "");
        vm.warp(vault.proposal(id).readyAt);
        vm.prank(owner);
        vm.expectRevert(O.InvalidOracle.selector);
        vault.execute(id);
    }

    function testNavCapLoweringVoidsRaisesAndCapApplies() public {
        uint256 id = _propose(T.Action.NavCap, address(0), abi.encode(uint256(2_000_000e18)));
        vm.prank(owner);
        vault.lowerNavCap(100e18);
        assertFalse(vault.proposalValid(id));
        vm.expectRevert(BaskVault.CapExceeded.selector);
        _deposit(2e18);
        assertGt(_deposit(1e18), 0);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.propose(T.Action.NavCap, address(0), abi.encode(uint256(10_000_000_000e18 + 1)));
    }

    function testSettingsBoundsAndCoupledGasConstraints() public {
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.propose(T.Action.Setting, address(0), abi.encode(T.Setting.Band, 1));
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.propose(T.Action.Setting, address(0), abi.encode(T.Setting.MaxAssets, 2));
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.propose(T.Action.Setting, address(0), abi.encode(T.Setting.BalanceGas, 500_000));
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.propose(T.Action.Setting, address(0), abi.encode(T.Setting.DirectLimit, 100));
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.propose(T.Action.Setting, address(0), abi.encode(T.Setting.MaxAssets, type(uint256).max));
        _setting(T.Setting.MaxAssets, 3);
        _setting(T.Setting.DirectLimit, 3);
        _setting(T.Setting.BalanceGas, 500_000);
        _setting(T.Setting.PayGas, 500_000);
        assertEq(vault.settings().balanceGas, 500_000);
    }

    function testSettingBoundsRecheckedAtExecution() public {
        uint256 a = _propose(T.Action.Setting, address(0), abi.encode(T.Setting.DirectLimit, 75));
        uint256 b = _propose(T.Action.Setting, address(0), abi.encode(T.Setting.PayGas, 400_000));
        _execute(a);
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.execute(b);
    }

    function testFeeRecipientCannotBeUnsetOrVault() public {
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.propose(T.Action.FeeRecipient, address(0), abi.encode(address(0)));
        vm.prank(owner);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.propose(T.Action.FeeRecipient, address(0), abi.encode(address(vault)));
    }

    function testOnlyOwnerCanUnpauseAndUnprivilegedCannotConfigure() public {
        vm.prank(guardian);
        vault.pauseDeposits();
        _status(T.Reason.Paused, address(0));
        vm.prank(guardian);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.unpauseDeposits();
        vm.prank(alice);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.close(address(tokens[0]));
        vm.prank(alice);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.propose(T.Action.FeeRecipient, address(0), abi.encode(alice));
        vm.prank(owner);
        vault.unpauseDeposits();
        _status(T.Reason.OK, address(0));
    }
}

contract LossTest is VaultFixture {
    function testLossDoesNotAutoReduceAndWaitsSevenDays() public {
        uint256 shares = _deposit(10e18);
        tokens[0].burn(address(vault), 4e18);
        _status(T.Reason.Deficit, address(tokens[0]));
        assertEq(vault.managed(address(tokens[0])), 10e18);
        vm.prank(bob);
        vault.flagDeficit(address(tokens[0]));
        (uint256 amount, uint256 since) = vault.deficits(address(tokens[0]));
        assertEq(amount, 4e18);
        vm.warp(since + 7 days - 1);
        vm.expectRevert(BaskVault.TooEarly.selector);
        vault.recognizeLoss(address(tokens[0]));
        vm.warp(since + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        assertEq(vault.managed(address(tokens[0])), 6e18);
        uint256[] memory legs = _redeem(shares / 2);
        assertEq(legs[0], 6e18 * (shares / 2) / 1000e18);
    }

    function testOnlyLargerLossRestartsClockAndRecoveredPartNotWrittenOff() public {
        _deposit(10e18);
        tokens[0].burn(address(vault), 2e18);
        vault.flagDeficit(address(tokens[0]));
        (, uint256 first) = vault.deficits(address(tokens[0]));
        vm.warp(first + 1 days);
        vault.flagDeficit(address(tokens[0]));
        (, uint256 same) = vault.deficits(address(tokens[0]));
        assertEq(same, first);
        tokens[0].burn(address(vault), 2e18);
        vault.flagDeficit(address(tokens[0]));
        (, uint256 second) = vault.deficits(address(tokens[0]));
        assertGt(second, first);
        tokens[0].mint(address(vault), 3e18);
        vm.warp(second + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        assertEq(vault.managed(address(tokens[0])), 9e18);
        (uint256 cleared,) = vault.deficits(address(tokens[0]));
        assertEq(cleared, 0);
    }

    function testUnreadableNeverFabricatesLossOrClearsRecord() public {
        _deposit(10e18);
        tokens[0].burn(address(vault), 2e18);
        vault.flagDeficit(address(tokens[0]));
        tokens[0].setModes(1, 0);
        vm.expectRevert(BaskVault.TransferFailed.selector);
        vault.flagDeficit(address(tokens[0]));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BaskVault.TransferFailed.selector);
        vault.recognizeLoss(address(tokens[0]));
        (uint256 amount,) = vault.deficits(address(tokens[0]));
        assertEq(amount, 2e18);
    }

    function testDepositAndHealthyFlagClearUnretiredRecords() public {
        _deposit(10e18);
        tokens[0].burn(address(vault), 1e18);
        vault.flagDeficit(address(tokens[0]));
        tokens[0].mint(address(vault), 1e18);
        _deposit(1e18);
        (uint256 cleared,) = vault.deficits(address(tokens[0]));
        assertEq(cleared, 0);
        tokens[0].burn(address(vault), 1e18);
        vault.flagDeficit(address(tokens[0]));
        tokens[0].mint(address(vault), 1e18);
        vault.flagDeficit(address(tokens[0]));
        (cleared,) = vault.deficits(address(tokens[0]));
        assertEq(cleared, 0);
    }

    function testRedeemWithBalanceBelowOwedLeavesManagedAndPaysZero() public {
        _setting(T.Setting.DirectLimit, 0);
        uint256 shares = _deposit(10e18);
        _redeem(shares / 2);
        uint256 m = vault.managed(address(tokens[0]));
        tokens[0].burn(address(vault), 9e18);
        uint256[] memory legs = _redeem(shares / 4);
        assertEq(legs[0], 0);
        assertEq(vault.managed(address(tokens[0])), m);
        vault.flagDeficit(address(tokens[0]));
        (uint256 loss,) = vault.deficits(address(tokens[0]));
        assertEq(loss, m);
    }

    function testRetiredRemovedOnlyAfterManagedAndClaimsEmpty() public {
        _setting(T.Setting.DirectLimit, 0);
        uint256 shares = _deposit(10e18);
        _redeem(shares);
        vm.prank(owner);
        vault.close(address(tokens[0]));
        _execute(_propose(T.Action.Retire, address(tokens[0]), ""));
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.removeRetired(address(tokens[0]));
        tokens[0].burn(address(vault), tokens[0].balanceOf(address(vault)));
        vault.flagDeficit(address(tokens[0]));
        vm.warp(block.timestamp + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.removeRetired(address(tokens[0]));
        tokens[0].mint(address(vault), vault.totalOwed(address(tokens[0])));
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), alice);
        vault.removeRetired(address(tokens[0]));
        assertEq(vault.assetCount(), 2);
    }
}
