// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {BaskTypes as T} from "../src/BaskTypes.sol";
import {BaskOracle as O} from "../src/libraries/BaskOracle.sol";
import {MockToken, MockFeed, MockPool, NoPauseToken} from "./Mocks.sol";

contract VaultFixture is Test {
    BaskVault internal vault;
    MockToken[] internal tokens;
    MockFeed[] internal feeds;
    address internal owner = address(bytes20(hex"30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3"));
    address internal guardian = address(bytes20(hex"5ed39AF86f2C00ad99913B5d727bD68f2A904B68"));
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal recipient = makeAddr("fee recipient");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(4663);
        vault = new BaskVault(owner, guardian);
        for (uint256 i; i < 3; ++i) {
            _add(18, 8, 100e8);
        }
        vm.prank(owner);
        vault.finalizeGenesis();
    }

    function _add(uint8 td, uint8 fd, int256 answer) internal returns (MockToken t, MockFeed f) {
        t = new MockToken(td);
        f = new MockFeed(fd, answer);
        tokens.push(t);
        feeds.push(f);
        vm.prank(owner);
        vault.genesisList(address(t), address(f), address(0), address(0), 0);
        t.mint(alice, 1_000_000 * 10 ** td);
        vm.prank(alice);
        t.approve(address(vault), type(uint256).max);
    }

    function _refresh() internal {
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].set(feeds[i].answer(), block.timestamp);
        }
    }

    function _one(address token) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = token;
    }

    function _amount(uint256 amount) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = amount;
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        vm.prank(alice);
        return vault.deposit(_one(address(tokens[0])), _amount(amount), alice, 0, block.timestamp);
    }

    function _propose(T.Action kind, address token, bytes memory data) internal returns (uint256 id) {
        vm.prank(owner);
        return vault.propose(kind, token, data);
    }

    function _execute(uint256 id) internal {
        vm.warp(vault.proposal(id).readyAt);
        _refresh();
        vm.prank(owner);
        vault.execute(id);
    }

    function _setting(T.Setting key, uint256 value) internal {
        _execute(_propose(T.Action.Setting, address(0), abi.encode(key, value)));
    }

    function _redeem(uint256 shares) internal returns (uint256[] memory amounts) {
        vm.prank(alice);
        return vault.redeem(shares, alice, new uint256[](0), block.timestamp);
    }

    function _status(T.Reason reason, address fault) internal view {
        (T.Reason actual, address token) = vault.depositStatus(_one(address(tokens[0])));
        assertEq(uint256(actual), uint256(reason));
        assertEq(token, fault);
    }
}

contract BasketAccountingTest is VaultFixture {
    function testShareTransferEventsUseStandardTopics() public {
        _execute(_propose(T.Action.FeeRecipient, address(0), abi.encode(recipient)));
        vm.recordLogs();
        uint256 shares = _deposit(1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Transfer(address,address,uint256)");
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != topic) continue;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[1], bytes32(0));
            address to = found == 0 ? address(0xdEaD) : found == 1 ? recipient : alice;
            uint256 amount = found == 0 ? 1e15 : found == 1 ? 0.5e18 : shares;
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(to))));
            assertEq(abi.decode(logs[i].data, (uint256)), amount);
            ++found;
        }
        assertEq(found, 3);
    }

    function testDeploymentAndMinimumLock() public {
        assertEq(vault.name(), "Basket");
        assertEq(vault.symbol(), "BASK");
        assertEq(vault.decimals(), 18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.owner(), owner);
        assertEq(vault.guardian(), guardian);
        assertLe(address(vault).code.length, 24_000);
        uint256 shares = _deposit(10e18);
        assertEq(shares, 1000e18 - 1e15);
        assertEq(vault.totalSupply(), 1000e18);
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.managed(address(tokens[0])), 10e18);
    }

    function testConstructorRejectsMissingAndEqualRoles() public {
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(address(0), guardian);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(owner, address(0));
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(owner, owner);
    }

    function testDonationDoesNotAffectSharesUntilResync() public {
        _deposit(10e18);
        tokens[0].mint(address(vault), 10e18);
        assertEq(_deposit(1e18), 100e18);
        _execute(_propose(T.Action.Resync, address(tokens[0]), ""));
        assertEq(vault.managed(address(tokens[0])), 21e18);
        assertEq(_deposit(1e18), uint256(100e18) * 1100e18 / 2100e18);
    }

    function testFeeDepositAndRedeemRounding() public {
        _execute(_propose(T.Action.FeeRecipient, address(0), abi.encode(recipient)));
        uint256 gross = 100e18 + 100;
        uint256 fee = gross / 200 + 1;
        uint256 shares = _deposit(1e18 + 1);
        assertEq(shares, gross - fee - 1e15);
        assertEq(vault.balanceOf(recipient), fee);
        uint256 beforeSupply = vault.totalSupply();
        uint256 toRedeem = 201;
        uint256[] memory paid = _redeem(toRedeem);
        assertEq(paid[0], (1e18 + 1) * 199 / beforeSupply);
        assertEq(vault.balanceOf(recipient), fee + 2);
        assertEq(vault.totalSupply(), beforeSupply - 199);
    }

    function testFirstDepositTinyAndSlippageFailAtomically() public {
        vm.expectRevert(BaskVault.Slippage.selector);
        _deposit(1);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.deposit(_one(address(tokens[0])), _amount(1e18), alice, 100e18, block.timestamp);
        assertEq(vault.totalSupply(), 0);
        assertEq(tokens[0].balanceOf(address(vault)), 0);
    }

    function testDuplicateInvalidAmountReceiverAndDeadline() public {
        address[] memory a = new address[](2);
        a[0] = address(tokens[0]);
        a[1] = a[0];
        uint256[] memory n = new uint256[](2);
        n[0] = 1e18;
        n[1] = 1e18;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, T.Reason.Duplicate, a[0]));
        vault.deposit(a, n, alice, 0, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.deposit(_one(a[0]), _amount(0), alice, 0, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.deposit(_one(a[0]), _amount(1e18), address(vault), 0, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Expired.selector);
        vault.deposit(_one(a[0]), _amount(1e18), alice, 0, block.timestamp - 1);
    }

    function testTransferAndAllowance() public {
        _deposit(10e18);
        vm.prank(alice);
        vault.approve(bob, 10e18);
        vm.prank(bob);
        vault.transferFrom(alice, bob, 10e18);
        assertEq(vault.allowance(alice, bob), 0);
        assertEq(vault.balanceOf(bob), 10e18);
        vm.prank(bob);
        vault.transfer(alice, 1e18);
        vm.prank(bob);
        vm.expectRevert(BaskVault.InsufficientBalance.selector);
        vault.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transfer(address(0), 1);
    }

    function testPreviewMatchesAndNoPriceOnRedeem() public {
        (uint256 expected,,) = vault.previewDeposit(_one(address(tokens[0])), _amount(10e18));
        uint256 shares = _deposit(10e18);
        assertEq(shares, expected);
        (uint256[] memory legs,) = vault.previewRedeem(shares / 2);
        for (uint256 i; i < 3; ++i) {
            feeds[i].setMode(2);
            tokens[i].setOraclePaused(true);
        }
        vm.prank(guardian);
        vault.pauseDeposits();
        uint256[] memory paid = _redeem(shares / 2);
        assertEq(paid, legs);
        assertEq(vault.owed(alice, address(tokens[0])), 0);
    }

    function testFeeOnTransferPullRejectedAndNoReturnSupported() public {
        tokens[0].setModes(0, 6);
        vm.expectRevert(BaskVault.TransferFailed.selector);
        _deposit(1e18);
        assertEq(vault.managed(address(tokens[0])), 0);
        tokens[0].setModes(0, 4);
        uint256 shares = _deposit(1e18);
        uint256[] memory legs = _redeem(shares);
        assertGt(legs[0], 0);
        assertEq(vault.owed(alice, address(tokens[0])), 0);
    }

    function testDepositChecksIdleUnreadableButSkipsRetired() public {
        tokens[1].setModes(1, 0);
        _status(T.Reason.BalanceUnreadable, address(tokens[1]));
        vm.prank(owner);
        vault.close(address(tokens[1]));
        _execute(_propose(T.Action.Retire, address(tokens[1]), ""));
        assertGt(_deposit(1e18), 0);
    }

    function testPausedBlockedFailedPaymentsAndPartialClaims() public {
        uint256 shares = _deposit(10e18);
        tokens[0].setBlocked(alice, true);
        uint256[] memory amounts = _redeem(shares / 2);
        uint256 debt = amounts[0];
        assertEq(vault.owed(alice, address(tokens[0])), debt);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), alice);
        assertEq(vault.owed(alice, address(tokens[0])), debt);
        tokens[0].burn(address(vault), 10e18 - debt / 2);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(tokens[0].balanceOf(bob), debt / 2);
        assertEq(vault.owed(alice, address(tokens[0])), debt - debt / 2);
        assertEq(vault.totalOwed(address(tokens[0])), debt - debt / 2);
    }

    function testNoRoleOrGasSettingLimitsClaimWork() public {
        uint256 shares = _deposit(10e18);
        _setting(T.Setting.BalanceGas, 20_000);
        _setting(T.Setting.PayGas, 20_000);
        tokens[0].setWork(40_000, 300_000);
        uint256[] memory amounts = _redeem(shares / 2);
        assertEq(vault.owed(alice, address(tokens[0])), amounts[0]);
        vm.prank(guardian);
        vault.pauseDeposits();
        vm.prank(owner);
        vault.close(address(tokens[0]));
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(vault.owed(alice, address(tokens[0])), 0);
        assertEq(tokens[0].balanceOf(bob), amounts[0]);
    }

    function testPaymentFailureRollsBackAllTokenEffects() public {
        uint256 shares = _deposit(10e18);
        for (uint256 mode = 3; mode <= 9; ++mode) {
            if (mode == 4 || mode == 6 || mode == 8) continue;
            tokens[0].setModes(0, mode);
            uint256 beforeBalance = tokens[0].balanceOf(address(vault));
            _redeem(shares / 10);
            assertEq(tokens[0].balanceOf(address(vault)), beforeBalance);
        }
        assertGt(vault.totalOwed(address(tokens[0])), 0);
    }

    function testDirectLimitZeroAlwaysCreditsAndOwedExcluded() public {
        _setting(T.Setting.DirectLimit, 0);
        uint256 shares = _deposit(10e18);
        uint256[] memory a = _redeem(shares / 2);
        assertEq(vault.totalOwed(address(tokens[0])), a[0]);
        uint256 remaining = vault.managed(address(tokens[0]));
        uint256 supply = vault.totalSupply();
        uint256[] memory b = _redeem(shares / 4);
        assertEq(b[0], remaining * (shares / 4) / supply);
        assertEq(tokens[0].balanceOf(address(vault)), 10e18);
    }

    function testRedeemMinimaFailureRestoresBurnAndTransfers() public {
        uint256 shares = _deposit(10e18);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(shares, alice, _amount(11e18), block.timestamp);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.managed(address(tokens[0])), 10e18);
    }

    function testReentrancyOnPullPayAndClaimFails() public {
        tokens[0].setCallback(address(vault), abi.encodeCall(vault.approve, (bob, 1)));
        uint256 shares = _deposit(10e18);
        assertFalse(tokens[0].callbackSucceeded());
        _redeem(shares / 4);
        assertFalse(tokens[0].callbackSucceeded());
        _setting(T.Setting.DirectLimit, 0);
        _redeem(shares / 4);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertFalse(tokens[0].callbackSucceeded());
        assertEq(vault.allowance(address(tokens[0]), bob), 0);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.pay(address(tokens[0]), bob, 1);
    }

    function testFuzzConservation(uint128 raw, uint16 fraction) public {
        uint256 amount = bound(raw, 1e14, 1000e18);
        uint256 shares = _deposit(amount);
        uint256 part = shares * bound(fraction, 1, 10_000) / 10_000;
        _redeem(part);
        assertEq(
            tokens[0].balanceOf(address(vault)), vault.managed(address(tokens[0])) + vault.totalOwed(address(tokens[0]))
        );
        assertEq(vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(address(0xdEaD)));
    }
}
