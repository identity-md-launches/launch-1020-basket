// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {BaskTypes as T} from "../src/BaskTypes.sol";
import {MockToken, MockFeed} from "./Mocks.sol";

contract RedemptionGasTest is Test {
    BaskVault private vault;
    address private owner = makeAddr("gas owner");
    address private guardian = makeAddr("gas guardian");
    address private alice = makeAddr("gas depositor");
    address private receiver = makeAddr("gas receiver");
    address[] private tokens;
    address[] private feeds;
    uint256 private shares;

    function _setting(T.Setting key, uint256 value) private {
        vm.prank(owner);
        uint256 id = vault.propose(T.Action.Setting, address(0), abi.encode(key, value));
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vault.execute(id);
    }

    function _setup(uint256 count, uint256 active, uint256 balanceGas, uint256 payGas, uint256 directLimit) private {
        vm.warp(1_800_000_000);
        vault = new BaskVault(owner, guardian);
        if (directLimit != 50) _setting(T.Setting.DirectLimit, 0);
        if (count < 250) _setting(T.Setting.MaxAssets, count);
        if (balanceGas != 50_000) _setting(T.Setting.BalanceGas, balanceGas);
        if (payGas != 250_000) _setting(T.Setting.PayGas, payGas);
        if (count > 250) _setting(T.Setting.MaxAssets, count);
        if (directLimit != 50) _setting(T.Setting.DirectLimit, directLimit);
        bytes memory tokenCode = address(new MockToken(18)).code;
        bytes memory feedCode = address(new MockFeed(0, 100)).code;
        address[] memory deposited = new address[](active);
        uint256[] memory amounts = new uint256[](active);
        for (uint256 i; i < count; ++i) {
            // Distinct local mocks, not deployment addresses.
            address token = address(uint160(0x100000 + i));
            address feed = address(uint160(0x200000 + i));
            vm.etch(token, tokenCode);
            vm.etch(feed, feedCode);
            MockFeed(feed).set(100, block.timestamp);
            tokens.push(token);
            feeds.push(feed);
            vm.prank(owner);
            vault.genesisList(token, feed, address(0), address(0), 0);
            if (i < active) {
                MockToken(token).mint(alice, 1e18);
                vm.prank(alice);
                MockToken(token).approve(address(vault), type(uint256).max);
                deposited[i] = token;
                amounts[i] = 1e18;
            }
        }
        vm.prank(owner);
        vault.finalizeGenesis();
        vm.prank(alice);
        shares = vault.deposit(deposited, amounts, alice, 0, block.timestamp);
    }

    function _hostile(uint256 balanceMode, uint256 transferMode) private {
        for (uint256 i; i < tokens.length; ++i) {
            MockToken(tokens[i]).setModes(balanceMode, transferMode);
            MockToken(tokens[i]).setOraclePaused(true);
            MockFeed(feeds[i]).setMode(2);
            vm.prank(guardian);
            vault.close(tokens[i]);
        }
        vm.prank(guardian);
        vault.pauseDeposits();
    }

    function _measure(string memory label) private returns (uint256 gasUsed) {
        // Clear all warmed account/storage accesses left by fixture setup.
        for (uint256 i; i < tokens.length; ++i) {
            vm.cool(tokens[i]);
            vm.cool(feeds[i]);
        }
        vm.cool(address(vault));
        bytes memory input = abi.encodeCall(vault.redeem, (shares / 2, receiver, new uint256[](0), block.timestamp));
        vm.prank(alice);
        uint256 start = gasleft();
        (bool ok, bytes memory data) = address(vault).call{gas: 28_000_000}(input);
        gasUsed = start - gasleft();
        assertTrue(ok, "redeem must fit in 28 million gas despite all dependencies failing");
        uint256[] memory legs = abi.decode(data, (uint256[]));
        assertEq(legs.length, tokens.length);
        assertGt(gasUsed, 100_000, "reject anomalous gas accounting");
        assertLt(gasUsed, 28_000_000);
        emit log_named_uint(label, gasUsed);
    }

    function testGas250UnreadableFullGasBurningAssets() public {
        _setup(250, 250, 50_000, 250_000, 50);
        _hostile(2, 2);
        _measure("250 unreadable assets gas");
        assertGt(vault.owed(receiver, tokens[249]), 0);
    }

    function testGas250AllPausedOrBlocked() public {
        _setup(250, 250, 50_000, 250_000, 50);
        for (uint256 i; i < 250; ++i) {
            MockToken(tokens[i]).setPaused(i % 2 == 0);
            MockToken(tokens[i]).setBlocked(receiver, i % 2 == 1);
        }
        _hostile(0, 0);
        _measure("250 paused or blocked assets gas");
        assertGt(vault.owed(receiver, tokens[0]), 0);
        assertGt(vault.owed(receiver, tokens[249]), 0);
    }

    function testGas250RetiredUnreadableAssetsStillRedeem() public {
        _setup(250, 250, 50_000, 250_000, 50);
        uint256[] memory ids = new uint256[](250);
        for (uint256 i; i < 250; ++i) {
            vm.prank(guardian);
            vault.close(tokens[i]);
            vm.prank(owner);
            ids[i] = vault.propose(T.Action.Retire, tokens[i], "");
        }
        vm.warp(block.timestamp + 2 days);
        for (uint256 i; i < 250; ++i) {
            vm.prank(owner);
            vault.execute(ids[i]);
            assertTrue(vault.asset(tokens[i]).retired);
        }
        _hostile(2, 2);
        uint256 expected = 1e18 * (shares / 2) / vault.totalSupply();
        _measure("250 retired assets with unreadable balances gas");
        for (uint256 i; i < 250; ++i) {
            assertEq(vault.owed(receiver, tokens[i]), expected);
            assertEq(vault.managed(tokens[i]), 1e18 - expected);
        }
    }

    function testGasDirect50TokensConsumeEntirePaymentAllowance() public {
        _setup(250, 50, 50_000, 250_000, 50);
        _hostile(2, 2);
        _measure("50 unreadable assets plus full payment failures gas");
        assertGt(vault.owed(receiver, tokens[49]), 0);
    }

    function testGasMaximumAssetSetting350Unreadable() public {
        _setup(350, 350, 20_000, 250_000, 50);
        _hostile(2, 2);
        _measure("350 unreadable assets at legal settings gas");
        assertGt(vault.owed(receiver, tokens[349]), 0);
    }

    function testGasMaximumDirectLimit254() public {
        _setup(350, 254, 20_000, 20_000, 254);
        _hostile(2, 2);
        _measure("254 direct attempts at legal settings gas");
        assertGt(vault.owed(receiver, tokens[253]), 0);
    }

    function testGasMaximumBalanceAndPaymentAllowance() public {
        _setup(49, 26, 500_000, 500_000, 26);
        _hostile(2, 2);
        _measure("26 direct attempts with 500k call allowances gas");
        assertGt(vault.owed(receiver, tokens[25]), 0);
    }

    function testGasMaximumBalance50Assets() public {
        _setup(50, 50, 500_000, 500_000, 26);
        _inflateAndEnableFee();
        _hostile(2, 2);
        _measure("50 deferred assets with 500k balance, 512-bit math and fee gas");
    }

    function testGas250AtBalanceCeilingWithHugeAccountingAndFees() public {
        _setup(250, 250, 52_000, 250_000, 50);
        _inflateAndEnableFee();
        _hostile(2, 2);
        _measure("250 assets at exact gas bound, 512-bit math and fee gas");
        assertGt(vault.owed(receiver, tokens[249]), 2 ** 200);
    }

    function _inflateAndEnableFee() private {
        uint256[] memory ids = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            MockToken(tokens[i]).mint(address(vault), type(uint256).max - 1e18);
            vm.prank(owner);
            ids[i] = vault.propose(T.Action.Resync, tokens[i], "");
        }
        vm.prank(owner);
        uint256 feeId = vault.propose(T.Action.FeeRecipient, address(0), abi.encode(guardian));
        vm.warp(block.timestamp + 2 days);
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(owner);
            vault.execute(ids[i]);
        }
        vm.prank(owner);
        vault.execute(feeId);
    }

    function testGasReturnBombsAndMalformedBalanceReads() public {
        _setup(250, 50, 50_000, 250_000, 50);
        _hostile(4, 8);
        _measure("bounded returndata gas");
        assertEq(vault.owed(receiver, tokens[0]), 0);
        for (uint256 i; i < 250; ++i) {
            MockToken(tokens[i]).setModes(3, 9);
        }
        _measure("malformed returndata gas");
        assertGt(vault.owed(receiver, tokens[0]), 0);
    }
}
